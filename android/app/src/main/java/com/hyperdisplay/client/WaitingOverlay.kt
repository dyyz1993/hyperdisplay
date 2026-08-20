package com.hyperdisplay.client

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 全断连等待页：WiFi 与 USB 都不可用/未连通时，全屏深色罩 + 两个通道图标
 * （WiFi 弧形信号 / USB 插头），正在尝试的通道高亮脉冲 + 下方动态状态文案。
 * 画面恢复即整体淡出移除。纯自绘（Canvas）——无资源依赖，帧动画只 invalidate
 * 两个小图标区域，开销可忽略。
 */
class WaitingOverlay(context: Context) : FrameLayout(context) {

    private val main = Handler(Looper.getMainLooper())
    private var started = false
    private var tick = 0L
    private val ticker = object : Runnable {
        override fun run() {
            tick++
            icons.invalidate()
            statusView.text = when {
                tryingUsb && tryingWifi -> "正在尝试 USB 与 WiFi 连接…"
                tryingUsb -> "正在等待 USB 连接…\n（确认数据线已插好、Mac 侧 host 在运行）"
                tryingWifi -> "正在搜索局域网内的 Mac…\n（确认与 Mac 在同一 WiFi，Mac 侧 host 在运行）"
                else -> "等待连接…"
            }
            main.postDelayed(this, 400)
        }
    }

    var tryingUsb = false
        set(v) { field = v; icons.invalidate() }
    var tryingWifi = false
        set(v) { field = v; icons.invalidate() }

    private val icons = object : View(context) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }

        override fun onDraw(c: Canvas) {
            val w = width.toFloat()
            val pulse = ((Math.sin(tick / 3.0) + 1) / 2).toFloat() // 0..1 呼吸
            drawWifi(c, w * 0.28f, tryingWifi, pulse)
            drawUsb(c, w * 0.72f, tryingUsb, pulse)
        }

        private fun drawWifi(c: Canvas, cx: Float, active: Boolean, pulse: Float) {
            val alpha = if (active) (100 + (pulse * 155)).toInt() else 60
            paint.strokeWidth = 10f
            paint.color = if (active) Color.argb(alpha, 80, 200, 120) else Color.argb(60, 160, 160, 160)
            val cy = height * 0.62f
            // 三级弧线信号
            for (i in 1..3) {
                val r = 26f * i
                val rect = RectF(cx - r, cy - r - 14f, cx + r, cy + r - 14f)
                c.drawArc(rect, -65f, 130f, false, paint)
            }
            fill.color = paint.color
            c.drawCircle(cx, cy + 12f, 9f, fill)
        }

        private fun drawUsb(c: Canvas, cx: Float, active: Boolean, pulse: Float) {
            val alpha = if (active) (100 + (pulse * 155)).toInt() else 60
            paint.strokeWidth = 10f
            paint.color = if (active) Color.argb(alpha, 80, 170, 255) else Color.argb(60, 160, 160, 160)
            val top = height * 0.30f
            val cy = height * 0.62f
            // 插头（矩形 + 两根探针）
            paint.style = Paint.Style.FILL
            val plugW = 34f
            c.drawRoundRect(cx - plugW / 2, cy - 46, cx + plugW / 2, cy - 6, 6f, 6f, paint)
            c.drawRect(cx - 12, top, cx - 4, cy - 46, paint)
            c.drawRect(cx + 4, top, cx + 12, cy - 46, paint)
            // 线缆弧
            paint.style = Paint.Style.STROKE
            c.drawLine(cx, cy - 6f, cx, cy + 18f, paint)
            c.drawCircle(cx, cy + 34f, 16f, paint)
        }
    }

    private val statusView = TextView(context).apply {
        textSize = 15f
        setTextColor(0xFFDDDDDD.toInt())
        gravity = Gravity.CENTER
        setLineSpacing(6f, 1f)
    }

    init {
        setBackgroundColor(0xEE101418.toInt())
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        box.addView(TextView(context).apply {
            text = "等待 Mac 主机"
            textSize = 22f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 40)
        })
        box.addView(icons, LinearLayout.LayoutParams(340, 260))
        box.addView(statusView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = 48
        })
        addView(box, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER))
    }

    fun show(root: FrameLayout) {
        if (parent == null) {
            alpha = 0f
            root.addView(this, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            animate().alpha(1f).setDuration(300).start()
        }
        if (!started) {
            started = true
            main.post(ticker)
        }
    }

    fun dismiss() {
        started = false
        main.removeCallbacks(ticker)
        animate().alpha(0f).setDuration(250).withEndAction {
            (parent as? FrameLayout)?.removeView(this)
        }.start()
    }
}
