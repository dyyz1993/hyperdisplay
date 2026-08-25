package com.hyperdisplay.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 传输切换触发器：插线（POWER_CONNECTED）立即触发 USB 探测回调——
 * WiFi 会话期间等 10s 轮询太慢（平均 5s、最坏 10s），插线事件把升级
 * 探测提速到秒级。轮询保留为兜底（接收器未注册/事件丢失时）。
 * 拔线（DISCONNECTED）不在这里处理：会话死亡走 onLinkEvent 降级路径。
 * 有线路径两条：adb 隧道（TCP，AGENTS.md §1 有线例外）与系统 USB/RNDIS
 * 网卡上的 UDP；前者由 UsbProbe 探测，后者由 mDNS 发现。
 */
class UsbPlugReceiver : BroadcastReceiver() {
    companion object {
        @Volatile var onPlugged: (() -> Unit)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_POWER_CONNECTED -> {
                // 前台已运行：只做升级探测回调（不弹通知）；未运行：通知拉起。
                // smart = 隧道优先，其次 USB 网卡 UDP / Wi-Fi，全部自动选路。
                if (onPlugged != null) {
                    onPlugged?.invoke()
                } else {
                    notifyUsbReady(context)
                }
            }
        }
    }

    private fun notifyUsbReady(context: Context) {
        val launch = Intent(context, MainActivity::class.java).apply {
            putExtra("host", "smart")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        try {
            context.startActivity(launch)
        } catch (_: Exception) {
            // Android 可能禁止后台拉起 Activity；下面的 full-screen PendingIntent 兜底。
        }
        val pi = android.app.PendingIntent.getActivity(
            context, 0, launch,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(android.app.NotificationChannel(
                "usb_plug", "USB 连线", android.app.NotificationManager.IMPORTANCE_HIGH))
        }
        val n = android.app.Notification.Builder(context, "usb_plug")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Mac 已连线")
            .setContentText("点按开始副屏")
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        nm.notify(1001, n)
    }
}
