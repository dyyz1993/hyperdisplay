package com.hyperdisplay.client

import android.content.Context

/**
 * USB 链路探测：完整握手（连上 + 发 HELLO + 等任意回包）。
 * 线断时 adbd 的监听 socket 仍在、connect 能成，但字节到不了 Mac——必须验回包。
 * Activity 的智能选路与插线广播接收器共用。
 */
object UsbProbe {
    fun probe(context: Context, result: (Boolean) -> Unit) {
        Thread {
            var ok = false
            try {
                val s = java.net.Socket()
                s.tcpNoDelay = true
                val v6 = java.net.InetAddress.getByAddress(
                    byteArrayOf(0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1))
                // 超时收紧（SLA：触发→见画面 ≤5s，目标 3s）：隧道在时握手是毫秒级，
                // 半开连接（adbd 活着但 Mac 侧死）才吃满超时——尽快失败尽快降级
                s.connect(java.net.InetSocketAddress(v6, 5280), 800)
                s.soTimeout = 1000
                // Activity.getPreferences 的实际文件名是 Activity 类名（getLocalClassName），
                // 非 Activity 上下文要显式同名，否则读到 0 → HELLO 被拒
                val prefs = context.getSharedPreferences(
                    "MainActivity", Context.MODE_PRIVATE)
                val code = prefs.getInt("pairingCode", 0)
                // 报文 = [type][seq u32][proto u8][w u16][h u16][code u32]。
                // proto=0xFF 探针标记：host 只回应不注册订阅——普通 HELLO 会被 host
                // 当真实客户端登记并订阅屏，充电状态变化触发的周期探测会把闲置回收
                // 卡死（显示永远"有人订着"，2026-08-20 实测）
                val hello = java.nio.ByteBuffer.allocate(14).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .put(0x10.toByte()).putInt(0).put(0xFF.toByte()).putShort(800).putShort(600)
                    .putInt(code).array()
                s.getOutputStream().write(java.nio.ByteBuffer.allocate(4 + hello.size)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .putInt(hello.size).put(hello).array())
                s.getOutputStream().flush()
                ok = s.getInputStream().read(ByteArray(64)) > 0
                s.close()
            } catch (_: Exception) { }
            android.util.Log.i("UsbProbe", "result=$ok")
            android.os.Handler(android.os.Looper.getMainLooper()).post { result(ok) }
        }.start()
    }
}
