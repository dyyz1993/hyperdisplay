package com.hyperdisplay.client

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.view.View

/** 本地光标：标准箭头鼠标指针（白底黑边，热点在左上角），手指/真光标位置零延迟绘制 */
class LocalCursorView(context: Context) : View(context) {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xF2FFFFFF.toInt()
        style = Paint.Style.FILL
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6000000.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 2.5f
    }

    private var cx = 0f
    private var cy = 0f
    @Volatile var visible = false

    // 单位箭头轮廓（尖在原点，向右下展开；高≈24，宽≈17）——绘制时按 scale 放大
    private val arrow = floatArrayOf(
        0f, 0f,   0f, 24f,   4.6f, 19.6f,   7.8f, 26.4f,   10.9f, 25f,
        7.8f, 18.4f,   13.4f, 18.2f
    )
    private val scale = 2.2f
    private val path = Path().apply {
        moveTo(arrow[0], arrow[1])
        for (i in 2 until arrow.size step 2) lineTo(arrow[i], arrow[i + 1])
        close()
    }

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
        canvas.save()
        // 热点对齐：指针尖端 = 目标坐标
        canvas.translate(cx, cy)
        canvas.scale(scale, scale)
        canvas.drawPath(path, fill)
        canvas.drawPath(path, stroke)
        canvas.restore()
    }
}
