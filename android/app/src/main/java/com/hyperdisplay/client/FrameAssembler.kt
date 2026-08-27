package com.hyperdisplay.client

/**
 * 视频分片重组，latest-frame 策略：
 * - 只重组当前最新的 frameId；更新的 frameId 到达即整体丢弃旧帧未完成分片；
 * - 检测到帧序号缺口（丢帧破坏依赖链）→ 进入「等待关键帧」状态，丢弃后续非关键帧，
 *   限频请求 IDR；
 * - 当前帧分片停滞超时同样视为丢失处理。
 */
class FrameAssembler(
    private val callback: Callback,
    private val debugLog: (String) -> Unit = { android.util.Log.d("FrameAssembler", it) }
) {
    interface Callback {
        fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray)
        fun onKeyframeNeeded(reason: String)
        /** 丢帧反馈：仅通知 host 拥塞；视频不重传旧分片。 */
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
    private var lastKeyframeRequestAt = 0L
    /** 整帧放弃的轻量反馈限流。空 NACK 表示拥塞，不代表“补 0 片”。 */
    private var lastCongestionReportAt = 0L
    private val lock = Object()

    fun onFragment(frameId: Int, fragIdx: Int, fragCount: Int, keyframe: Boolean, payload: ByteArray) {
        synchronized(lock) {
            val now = System.currentTimeMillis()

            if (frameId < currentFrameId) return // 过期分片
            if (frameId > currentFrameId) {
                // 起流/丢帧恢复时，正在接收的 IDR 是唯一能重建解码参考链的锚点。
                // 旧逻辑把它立刻让给后来抵达的 P 帧；在手机 Wi-Fi 上一个 IDR 往往
                // 需要数十毫秒到数百毫秒，结果每次还没收完就被下一帧抢走，形成
                // “丢 IDR → 再要 IDR → 再被 P 帧抢走”的黑屏循环。只在等 IDR 且
                // 当前 IDR 尚未完成时忽略后续非关键帧；更新的 IDR 仍可替换旧 IDR。
                if (waitingForKeyframe && currentKeyframe && !deliveredCurrent &&
                    !isComplete() && !keyframe) {
                    return
                }
                // 新帧开始；旧帧未投递且缺分片才视为丢弃（latest-frame policy）
                if (currentFrameId >= 0 && !deliveredCurrent && !isComplete()) {
                    onAbandoned()
                    if (currentKeyframe) {
                        abandonKeyframe(currentFrameId, now)
                    } else if (everGotKeyframe) {
                        waitingForKeyframe = true
                        reportCongestionRateLimited(currentFrameId, "incomplete delta", now)
                        requestKeyframeRateLimited("incomplete delta $currentFrameId", now)
                    }
                }
                if (lastDeliveredFrameId >= 0 && frameId > lastDeliveredFrameId + 1 && everGotKeyframe) {
                    // 这台华为的 HEVC 硬解对断引用 P 帧会直接输出整帧绿色；宁可保留
                    // 上一张画面等待干净 IDR，也不能把它送进解码器污染输出面。
                    waitingForKeyframe = true
                    reportCongestionRateLimited(frameId, "frame gap", now)
                    requestKeyframeRateLimited("gap $lastDeliveredFrameId -> $frameId", now)
                }
                currentFrameId = frameId
                currentFragCount = fragCount
                currentKeyframe = keyframe
                deliveredCurrent = false
                fragments = arrayOfNulls(fragCount)
            }

            if (fragIdx >= fragments.size) return
            lastFragmentAt = now
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
                        onAbandoned()
                        return // 会话最初：解码器还没有任何参考帧，必须等 IDR
                    }
                    everGotKeyframe = true
                    waitingForKeyframe = false
                }
                if (keyframe) {
                    waitingForKeyframe = false
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
                if (waitingForKeyframe) requestKeyframeRateLimited("idle-wait", System.currentTimeMillis())
                return
            }
            if (deliveredCurrent || isComplete()) return
            val idle = System.currentTimeMillis() - lastFragmentAt
            // 视频不补传：缺片的 IDR 已经过期，不能等秒级；但仍给 Wi-Fi 的短暂
            // 抖动和 Host 的 90ms 分片节流留出 250ms 乱序窗口。
            val patience = 250L
            if (idle > patience) {
                onAbandoned()
                if (currentKeyframe) {
                    abandonKeyframe(currentFrameId, System.currentTimeMillis())
                } else if (everGotKeyframe) {
                    waitingForKeyframe = true
                    reportCongestionRateLimited(currentFrameId, "delta stall", System.currentTimeMillis())
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
        }
    }

    /** 已编码帧进不了解码 FIFO 时，后续 P 帧不能跨过缺口继续送硬解。 */
    fun requireKeyframeAfterDecoderBackpressure(frameId: Int) {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            waitingForKeyframe = true
            reportCongestionRateLimited(frameId, "decoder queue full", now)
            requestKeyframeRateLimited("decoder queue full at $frameId", now)
        }
    }

    private fun isComplete(): Boolean = fragments.isNotEmpty() && fragments.all { it != null }

    private fun abandonKeyframe(frameId: Int, now: Long) {
        val missing = fragments.indices.filter { fragments[it] == null }
        reportCongestionRateLimited(frameId, "keyframe missing ${missing.size}", now)
        requestKeyframeRateLimited("discard stale keyframe $frameId", now)
    }

    private fun reportCongestionRateLimited(frameId: Int, reason: String, now: Long) {
        if (now - lastCongestionReportAt < 750) return
        lastCongestionReportAt = now
        debugLog("receiver congested: $reason")
        callback.onNackKeyframeFragments(frameId, emptyList())
    }

    private fun onAbandoned() {
        // latest-frame 的正常工作就是大量放弃过期帧。以前这里逐帧 Log.d，双屏滚动时
        // 每秒会刷数百行 logcat，日志 I/O 反过来抢走解码线程，制造“越查越卡”。
        // 真正影响恢复的状态已通过限流的空 NACK / keyframe request 上报，无需逐帧打印。
    }

    private fun requestKeyframeRateLimited(reason: String, now: Long) {
        // Host 端还会做 250ms 去重。客户端不能再额外等满 1 秒，否则一次正常
        // latest-frame 跳帧会把“等干净 IDR”的安全策略放大成肉眼可见的秒级卡顿。
        // 500ms 既不给关键帧在途制造请求风暴，也能在首次请求丢失时快速补救。
        if (now - lastKeyframeRequestAt < 500) return
        lastKeyframeRequestAt = now
        debugLog("keyframe requested: $reason")
        callback.onKeyframeNeeded(reason)
    }
}
