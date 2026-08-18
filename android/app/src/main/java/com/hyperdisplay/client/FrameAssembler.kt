package com.hyperdisplay.client

/**
 * 视频分片重组，latest-frame 策略：
 * - 只重组当前最新的 frameId；更新的 frameId 到达即整体丢弃旧帧未完成分片；
 * - 检测到帧序号缺口（丢帧破坏依赖链）→ 进入「等待关键帧」状态，丢弃后续非关键帧，
 *   限频（≥500ms）请求 IDR；
 * - 当前帧分片停滞超时同样视为丢失处理。
 */
class FrameAssembler(private val callback: Callback) {
    interface Callback {
        fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray)
        fun onKeyframeNeeded(reason: String)
    }

    private var lastDeliveredFrameId = -1
    private var currentFrameId = -1
    private var currentFragCount = 0
    private var currentKeyframe = false
    private var fragments = arrayOfNulls<ByteArray>(0)
    private var lastFragmentAt = 0L
    private var waitingForKeyframe = true
    private var lastKeyframeRequestAt = 0L
    private val lock = Object()

    fun onFragment(frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray) {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            lastFragmentAt = now

            if (frameId < currentFrameId) return // 过期分片
            if (frameId > currentFrameId) {
                // 新帧开始（旧帧未完成则被丢弃——latest-frame policy）
                if (currentFrameId >= 0 && !isComplete()) onAbandoned(currentFrameId)
                if (lastDeliveredFrameId >= 0 && frameId > lastDeliveredFrameId + 1 && !waitingForKeyframe) {
                    waitingForKeyframe = true
                    requestKeyframeRateLimited("gap $lastDeliveredFrameId -> $frameId", now)
                }
                currentFrameId = frameId
                currentFragCount = fragCount
                currentKeyframe = keyframe
                fragments = arrayOfNulls(fragCount)
            }

            if (fragIdx >= fragments.size) return
            if (fragments[fragIdx] == null) fragments[fragIdx] = payload

            if (isComplete()) {
                val total = fragments.sumOf { it!!.size }
                val out = ByteArray(total)
                var offset = 0
                for (frag in fragments) {
                    System.arraycopy(frag!!, 0, out, offset, frag.size)
                    offset += frag.size
                }
                fragments = arrayOfNulls(0)
                lastDeliveredFrameId = frameId
                if (waitingForKeyframe) {
                    if (!keyframe) {
                        onAbandoned(frameId)
                        return // 依赖链断裂后的非关键帧，丢弃
                    }
                    waitingForKeyframe = false
                }
                callback.onFrame(frameId, keyframe, out)
            }
        }
    }

    /** 由外部周期调用（≥100ms 一次）：分片停滞检测 */
    fun stallCheck() {
        synchronized(lock) {
            if (currentFrameId < 0 || isComplete()) return
            val idle = System.currentTimeMillis() - lastFragmentAt
            if (idle > 300) {
                onAbandoned(currentFrameId)
                currentFrameId = -1
                fragments = arrayOfNulls(0)
                waitingForKeyframe = true
                requestKeyframeRateLimited("stall ${idle}ms", System.currentTimeMillis())
            }
        }
    }

    /** host 重启/重连后调用 */
    fun reset() {
        synchronized(lock) {
            lastDeliveredFrameId = -1
            currentFrameId = -1
            fragments = arrayOfNulls(0)
            waitingForKeyframe = true
        }
    }

    private fun isComplete(): Boolean = fragments.isNotEmpty() && fragments.all { it != null }

    private fun onAbandoned(frameId: Int) {
        android.util.Log.d("FrameAssembler", "abandon incomplete frame $frameId")
    }

    private fun requestKeyframeRateLimited(reason: String, now: Long) {
        if (now - lastKeyframeRequestAt < 500) return
        lastKeyframeRequestAt = now
        android.util.Log.d("FrameAssembler", "keyframe requested: $reason")
        callback.onKeyframeNeeded(reason)
    }
}
