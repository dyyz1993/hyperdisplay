package com.hyperdisplay.client

import android.content.Context
import android.graphics.RectF
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * 单个虚拟屏的渲染视图（分屏模式下每块屏一个实例）。
 * 流内容按宽高比 aspect-fit 到视图；触摸只接受落在内容区内的点。
 */
class StreamView(context: Context) : SurfaceView(context), SurfaceHolder.Callback {
    var displayId = -1
    @Volatile var streamWidth = 0f
    @Volatile var streamHeight = 0f
    var onSurfaceReady: ((Int, Surface) -> Unit)? = null
    var onSurfaceDestroyed: ((Int) -> Unit)? = null
    var onTouch: ((Int, MotionEvent) -> Boolean)? = null

    init {
        holder.addCallback(this)
        holder.setKeepScreenOn(true)
    }

    fun updateStreamSize(w: Int, h: Int) {
        streamWidth = w.toFloat()
        streamHeight = h.toFloat()
        holder.setFixedSize(w, h) // SurfaceView 缓冲 = 流原生分辨率，缩放交给合成器
    }

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

    fun viewToStream(x: Float, y: Float): FloatArray? {
        val rect = contentRect() ?: return null
        if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) return null
        val sx = (x - rect.left) / rect.width() * streamWidth
        val sy = (y - rect.top) / rect.height() * streamHeight
        return floatArrayOf(sx, sy)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val id = displayId
        if (id < 0) return false
        return onTouch?.invoke(id, event) ?: false
    }

    // SurfaceHolder.Callback
    override fun surfaceCreated(holder: SurfaceHolder) { }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        onSurfaceReady?.invoke(displayId, holder.surface)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke(displayId)
    }
}
