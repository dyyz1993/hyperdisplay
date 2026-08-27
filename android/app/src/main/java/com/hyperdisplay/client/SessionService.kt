package com.hyperdisplay.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder

/** 会话前台服务：通知栏常驻一项，防止系统（华为等激进后台管理）杀掉副屏连接。
 *  副屏应用必须后台存活——用户切去别的 app 时串流不能断。 */
class SessionService : Service() {

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(
            CHANNEL_ID, "屏幕连接", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持与 Mac 的副屏连接"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        return START_STICKY
    }

    private fun goForeground() {
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Hyperdisplay 副屏运行中")
            .setContentText("连接保持中 · 点按返回")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 从最近任务划掉属于明确“离开副屏”的动作，不等 Activity 的后台宽限。
        // 回调仍有机会发出 BYE；若 ROM 直接硬杀进程，Mac 端的心跳失活回收兜底。
        onTaskRemovedCallback?.invoke()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        const val CHANNEL_ID = "hyperdisplay_session"
        const val NOTIFICATION_ID = 1
        @Volatile var onTaskRemovedCallback: (() -> Unit)? = null
    }
}
