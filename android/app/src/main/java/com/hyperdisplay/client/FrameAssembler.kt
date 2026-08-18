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
        /** 关键帧缺片 NACK：请求 host 重传（增量帧可丢，关键帧必须完整） */
        fun onNackKeyframeFragments(frameId: Int, missing: List<Int>)
    }

    private var lastDeliveredFrameId = -1
    private var currentFrameId = -1
    private var currentFragCount = 0
    private var currentKeyframe = false
    private var fragments = arrayOfNulls<ByteArray>(0)
    private var deliveredCurrent = false
    private var lastFragmentAt = 0L
    private var waitingForKeyframe = true   // 仅用于会话最初：第一帧必须是 IDR
    private var everGotKeyframe = false
    private var degraded = false            // 丢包后降级续播：增量帧照放（允许糊/花），后台刷新 IDR
    private var lastKeyframeRequestAt = 0L
    private val lock = Object()

    fun onFragment(frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray) {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            lastFragmentAt = now

            if (frameId < currentFrameId) return // 过期分片
            if (frameId > currentFrameId) {
                // 新帧开始；旧帧未投递且缺分片才视为丢弃（latest-frame policy）
                if (currentFrameId >= 0 && !deliveredCurrent && !isComplete()) {
                    onAbandoned(currentFrameId)
                    if (currentKeyframe) {
                        nackMissing(currentFrameId)
                    } else if (everGotKeyframe) {
                        waitingForKeyframe = true
                        requestKeyframeRateLimited("incomplete delta $currentFrameId", now)
                    }
                }
                if (lastDeliveredFrameId >= 0 && frameId > lastDeliveredFrameId + 1 && everGotKeyframe) {
                    // 帧序号缺口：依赖链已断。丢弃后续增量直到干净 IDR（实测华为硬解对
                    // 断链增量输出整帧绿色伪影，比短暂冻结更差）；限频请求 IDR 尽快恢复。
                    waitingForKeyframe = true
                    requestKeyframeRateLimited("gap $lastDeliveredFrameId -> $frameId", now)
                }
                currentFrameId = frameId
                currentFragCount = fragCount
                currentKeyframe = keyframe
                deliveredCurrent = false
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
                deliveredCurrent = true
                lastDeliveredFrameId = frameId
                if (waitingForKeyframe) {
                    if (!keyframe) {
                        onAbandoned(frameId)
                        return // 会话最初：解码器还没有任何参考帧，必须等 IDR
                    }
                    everGotKeyframe = true
                    waitingForKeyframe = false
                }
                if (keyframe) {
                    degraded = false
                }
                callback.onFrame(frameId, keyframe, out)
            }
        }
    }

    /** 由外部周期调用（≥100ms 一次）：分片停滞检测 */
    fun stallCheck() {
        synchronized(lock) {
            if (currentFrameId < 0) {
                // 等关键帧但没有任何分片到达（如首帧全丢）：NACK 无从触发，周期性请求 IDR
                if (waitingForKeyframe || degraded) requestKeyframeRateLimited("idle-wait", System.currentTimeMillis())
                return
            }
            if (deliveredCurrent || isComplete()) return
            val idle = System.currentTimeMillis() - lastFragmentAt
            if (idle > 300) {
                onAbandoned(currentFrameId)
                if (currentKeyframe) {
                    nackMissing(currentFrameId)
                } else if (everGotKeyframe) {
                    waitingForKeyframe = true
                }
                currentFrameId = -1
                fragments = arrayOfNulls(0)
                if (!everGotKeyframe) waitingForKeyframe = true
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
            everGotKeyframe = false
            degraded = false
        }
    }

    private fun isComplete(): Boolean = fragments.isNotEmpty() && fragments.all { it != null }

    private var lastNackAt = 0L

    private fun nackMissing(frameId: Int) {
        val now = System.currentTimeMillis()
        if (now - lastNackAt < 150) return // NACK 节流
        val missing = fragments.indices.filter { fragments[it] == null }
        if (missing.isEmpty()) return
        lastNackAt = now
        // 丢片过多时分批请求（单包上限 255），剩余由下一轮 stall/NACK 继续
        callback.onNackKeyframeFragments(frameId, missing.take(255))
    }

    private fun onAbandoned(frameId: Int) {
        val missing = fragments.indices.filter { fragments[it] == null }
        android.util.Log.d("FrameAssembler",
            "abandon incomplete frame $frameId fragCount=$currentFragCount missing=$missing")
    }

    private fun requestKeyframeRateLimited(reason: String, now: Long) {
        // 1000ms 退避：大关键帧在途时反复请求只会加剧拥塞（自 DDoS）
        if (now - lastKeyframeRequestAt < 1000) return
        lastKeyframeRequestAt = now
        android.util.Log.d("FrameAssembler", "keyframe requested: $reason")
        callback.onKeyframeNeeded(reason)
    }
}
