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
                s.connect(java.net.InetSocketAddress(v6, 5280), 1500)
                s.soTimeout = 1500
                // Activity.getPreferences 的实际文件名是 Activity 类名（getLocalClassName），
                // 非 Activity 上下文要显式同名，否则读到 0 → HELLO 被拒
                val prefs = context.getSharedPreferences(
                    "MainActivity", Context.MODE_PRIVATE)
                val code = prefs.getInt("pairingCode", 0)
                // 报文 = [type][seq u32][proto u8][w u16][h u16][code u32]
                val hello = java.nio.ByteBuffer.allocate(14).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .put(0x10.toByte()).putInt(0).put(1.toByte()).putShort(800).putShort(600)
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
