package com.hyperdisplay.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 插线自动拉起（零点击，AGENTS.md §7.1）：
 * 任何供电接入（含 Mac USB）都触发本接收器——静默探测 USB 隧道，
 * 只有隧道握手成功（= 确实插在跑着 host 的 Mac 上）才提醒；
 * 插充电器时探测失败，零打扰。
 *
 * Android 10+ 后台禁止直接 startActivity，用 fullScreenIntent 通知：
 * 亮屏时是横幅点一下，息屏时直接全屏拉起。
 */
class UsbPlugReceiver : BroadcastReceiver() {
    companion object {
        private const val CHANNEL = "usb_plug"
        private const val NOTIFY_ID = 1001
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_POWER_CONNECTED) return
        val pending = goAsync()
        UsbProbe.probe(context) { ok ->
            if (ok) notifyUsbReady(context)
            pending.finish()
        }
    }

    private fun notifyUsbReady(context: Context) {
        val launch = Intent(context, MainActivity::class.java).apply {
            putExtra("host", "smart")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL, "USB 连线", NotificationManager.IMPORTANCE_HIGH))
        }
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Mac 已连线")
            .setContentText("点按开始副屏")
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFY_ID, n)
    }
}
