package com.hyperdisplay.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 插线入口：唤起客户端重新探测网络。只有系统真正提供 USB/RNDIS 网卡时才会
 * 走 USB UDP；MTP/PTP/HiSuite 都只是文件或设备管理协议，不能承载实时画面。
 * 没有 USB UDP 路径时自动继续使用 Wi-Fi，不会降级成 TCP。
 */
class UsbPlugReceiver : BroadcastReceiver() {
    companion object {
        @Volatile var onPlugged: (() -> Unit)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_POWER_CONNECTED -> {
                // 前台已运行：直接重新发现；后台：尝试直接拉起，系统若拦截则由
                // 全屏通知兜底。两条路径都会自动发现 UDP host，无需输入地址。
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
            putExtra("host", "discover")
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
            .setContentTitle("检测到 USB 连接")
            .setContentText("正在探测 USB 网卡；MTP 仅传文件，没有 USB 网卡时自动使用 Wi-Fi")
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        nm.notify(1001, n)
    }
}
