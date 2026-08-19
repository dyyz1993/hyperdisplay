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
        holder.setFixedSize(w, h)
        fitAspect()
    }

    /** 视图贴合流宽高比（居中，父容器余量露黑边）——SurfaceView 缓冲会被
     *  合成器拉伸到视图大小，视图不贴合比例画面必然变形（手机上实测过）。 */
    private fun fitAspect() {
        if (streamWidth <= 0 || streamHeight <= 0) return
        val parent = parent as? android.view.ViewGroup ?: return
        post {
            val pw = parent.width.toFloat()
            val ph = parent.height.toFloat()
            if (pw <= 0 || ph <= 0) return@post
            val scale = minOf(pw / streamWidth, ph / streamHeight)
            val tw = (streamWidth * scale).toInt()
            val th = (streamHeight * scale).toInt()
            val lp = layoutParams as? android.view.ViewGroup.MarginLayoutParams ?: return@post
            if (lp.width != tw || lp.height != th) {
                lp.width = tw
                lp.height = th
                lp.setMargins(((pw - tw) / 2).toInt(), ((ph - th) / 2).toInt(), 0, 0)
                layoutParams = lp
            }
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        fitAspect()
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

    /** 流坐标 → 视图坐标；越界返回 null */
    fun streamToView(sx: Float, sy: Float): FloatArray? {
        val rect = contentRect() ?: return null
        if (sx < 0 || sx > streamWidth || sy < 0 || sy > streamHeight) return null
        return floatArrayOf(
            rect.left + sx / streamWidth * rect.width(),
            rect.top + sy / streamHeight * rect.height())
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
