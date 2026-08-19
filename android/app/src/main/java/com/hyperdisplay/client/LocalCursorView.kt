package com.hyperdisplay.client

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View

/** 本地光标：手指位置零延迟绘制（远程画面中的系统光标已被 host 隐藏） */
class LocalCursorView(context: Context) : View(context) {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xF2FFFFFF.toInt()
        style = Paint.Style.FILL
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6000000.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 3f
    }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xE6000000.toInt() }

    private var cx = 0f
    private var cy = 0f
    @Volatile var visible = false

    fun moveTo(x: Float, y: Float) {
        cx = x
        cy = y
        visible = true
        postInvalidate()
    }

    fun hide() {
        visible = false
        postInvalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (!visible) return
        // 圆形光标（白底黑边 + 中心点），远看清晰
        canvas.drawCircle(cx, cy, 26f, fill)
        canvas.drawCircle(cx, cy, 26f, stroke)
        canvas.drawCircle(cx, cy, 4f, dot)
    }
}
