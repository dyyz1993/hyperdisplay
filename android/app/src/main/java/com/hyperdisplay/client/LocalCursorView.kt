package com.hyperdisplay.client

import android.content.Context
import android.graphics.Canvas
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import java.nio.ByteBuffer
import android.view.View

/**
 * 本地光标：标准箭头鼠标指针（白底黑边，热点在左上角）。
 *
 * Host 的坐标包会有轻微 Wi-Fi 抖动；这里不逐包立即跳到目标点，而是让渲染位置以
 * 极短的一帧插值追上目标，并且只在 Android 的 VSync 绘制。这样不影响真实鼠标
 * 的控制权（它仍完全在 Mac），但视觉上没有 30Hz 台阶和到包时间不均造成的顿挫。
 */
class LocalCursorView(context: Context) : View(context) {
    private val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x55000000
        style = Paint.Style.FILL
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFAFBFC.toInt()
        style = Paint.Style.FILL
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xD9232B36.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 1.35f
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }
    private val systemCursorPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        isDither = false
    }

    private var cx = 0f
    private var cy = 0f
    private var targetX = 0f
    private var targetY = 0f
    private var hasPosition = false
    @Volatile var visible = false
    private var systemCursor: Bitmap? = null
    private var systemHotX = 0f
    private var systemHotY = 0f
    // macOS 光标原始位图按桌面像素给出（典型箭头仅 28×40）；直接 1:1 放到高分
    // 平板会显得过小。仅放大绘制，不改变 Host 坐标和热点语义。
    private val systemCursorScale = 2f

    // 接近 macOS 的紧凑箭头：热点在尖端，主体白、细深色描边；比旧版更窄、更小，
    // 但在平板高分屏上仍能从视频画面中一眼辨认。
    private val arrow = floatArrayOf(
        0.8f, 0.8f,   1.2f, 23.2f,   6.0f, 18.1f,   10.0f, 27.3f,
        13.5f, 25.8f,  9.5f, 16.7f,  16.4f, 16.4f
    )
    // 旧版 2.2 → 约 53px 高；这里约 38px，高速移动时更像桌面指针而不是触控光标。
    private val scale = 1.45f
    private val path = Path().apply {
        moveTo(arrow[0], arrow[1])
        for (i in 2 until arrow.size step 2) lineTo(arrow[i], arrow[i + 1])
        close()
    }

    fun moveTo(x: Float, y: Float) {
        targetX = x
        targetY = y
        if (!hasPosition) {
            // 首包必须立即出现，不能为了平滑从左上角飞入。
            cx = x
            cy = y
            hasPosition = true
        }
        visible = true
        postInvalidateOnAnimation()
    }

    fun hide() {
        visible = false
        postInvalidateOnAnimation()
    }

    /**
     * Android ARGB_8888 在 little-endian 内存中的字节顺序正是 BGRA，故可零拷贝解释
     * macOS 的当前系统光标像素；不猜手型/I-beam/缩放箭头，所有 App 自定义光标也一致。
     */
    fun setSystemCursor(width: Int, height: Int, hotX: Int, hotY: Int, bgra: ByteArray) {
        if (width !in 1..256 || height !in 1..256 || bgra.size != width * height * 4) return
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(bgra))
        systemCursor = bitmap
        systemHotX = hotX.coerceIn(0, width).toFloat()
        systemHotY = hotY.coerceIn(0, height).toFloat()
        postInvalidateOnAnimation()
    }

    override fun onDraw(canvas: Canvas) {
        if (!visible) return
        // 0.72 约为一帧内追上大部分误差：看起来连续，同时只引入不到一帧的视觉
        // 滞后。目标未到时继续请求下一次 VSync；没有新光标包时不会常驻刷新。
        val dx = targetX - cx
        val dy = targetY - cy
        if (dx * dx + dy * dy > 0.25f) {
            cx += dx * 0.72f
            cy += dy * 0.72f
            postInvalidateOnAnimation()
        } else {
            cx = targetX
            cy = targetY
        }
        canvas.save()
        // 热点对齐：指针尖端 = 目标坐标
        canvas.translate(cx, cy)
        val bitmap = systemCursor
        if (bitmap != null) {
            canvas.scale(systemCursorScale, systemCursorScale)
            canvas.drawBitmap(bitmap, -systemHotX, -systemHotY, systemCursorPaint)
            canvas.restore()
            return
        }
        canvas.scale(scale, scale)
        // 不开软件层，直接画一层偏移阴影；成本极小，视频 Surface 上也稳定。
        canvas.save()
        canvas.translate(1.1f, 1.4f)
        canvas.drawPath(path, shadow)
        canvas.restore()
        canvas.drawPath(path, fill)
        canvas.drawPath(path, stroke)
        canvas.restore()
    }
}
