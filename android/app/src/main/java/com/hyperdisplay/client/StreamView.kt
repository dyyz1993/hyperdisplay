package com.hyperdisplay.client

import android.content.Context
import android.graphics.RectF
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * 全屏渲染 SurfaceView + 流内容几何。
 * 流内容按宽高比 aspect-fit 到视图（居中 letterbox）；触摸只接受落在内容区内的点。
 */
class StreamView(context: Context) : SurfaceView(context), SurfaceHolder.Callback {
    @Volatile var streamWidth = 0f
    @Volatile var streamHeight = 0f
    var onSurfaceReady: ((Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null
    var onTouch: ((MotionEvent) -> Boolean)? = null

    init {
        holder.addCallback(this)
    }

    fun updateStreamSize(w: Int, h: Int) {
        streamWidth = w.toFloat()
        streamHeight = h.toFloat()
        holder.setFixedSize(w, h) // SurfaceView 缓冲 = 流原生分辨率，缩放交给合成器
    }

    /** 流内容在视图坐标里的显示矩形 */
    fun contentRect(): RectF? {
        if (streamWidth <= 0 || streamHeight <= 0) return null
        val vw = width.toFloat()
        val vh = height.toFloat()
        if (vw <= 0 || vh <= 0) return null
        val scale = minOf(vw / streamWidth, vh / streamHeight)
        val w = streamWidth * scale
        val h = streamHeight * scale
        return RectF((vw - w) / 2f, (vh - h) / 2f, (vw + w) / 2f, (vh + h) / 2f)
    }

    /** 视图坐标 → 流坐标；越界返回 null */
    fun viewToStream(x: Float, y: Float): FloatArray? {
        val rect = contentRect() ?: return null
        if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) return null
        val sx = (x - rect.left) / rect.width() * streamWidth
        val sy = (y - rect.top) / rect.height() * streamHeight
        return floatArrayOf(sx, sy)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        return onTouch?.invoke(event) ?: false
    }

    // SurfaceHolder.Callback
    override fun surfaceCreated(holder: SurfaceHolder) { }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        onSurfaceReady?.invoke(holder.surface)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke()
    }
}
