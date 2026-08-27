package com.hyperdisplay.client

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MediaCodec 同步解码循环：
 * - 输入侧保留已编码帧 FIFO；队列满时拒绝新帧并要求上层等待 IDR，绝不跨过 P 帧；
 * - 输出侧一次吐多帧时只渲染最新，其余 release(false) 丢弃。
 */
class VideoDecoder(
    private val mime: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val surface: Surface,
    private val csd0: ByteArray
) {
    companion object {
        private const val TAG = "VideoDecoder"
        private const val IDLE_INPUT_WAIT_MS = 50L
        private const val INPUT_BUFFER_WAIT_US = 2_000L
        private const val OUTPUT_WAIT_AFTER_INPUT_US = 5_000L
    }

    class Frame(val keyframe: Boolean, val data: ByteArray)

    private val codec: MediaCodec = MediaCodec.createDecoderByType(mime)
    private val queue = ArrayBlockingQueue<Frame>(4)
    private val running = AtomicBoolean(false)
    private val thread = Thread({ loop() }, "hyperdisplay-decoder")
    private var ptsIndex = 0L
    private val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)
    @Volatile var renderedFrames: Int = 0
        private set
    @Volatile private var inputSubmitted = 0L

    fun start() {
        // KEY_CSD_0 在部分 SDK 中不对外导出，直接用其稳定字面值 "csd-0"
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd0))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 21)
            // 与 Host WELCOME 协商的节奏一致。之前 PTS 固定 33.3ms，即使 Host
            // 已 60fps 采集，部分硬解仍会把流当 30fps 调度，滚动/动画会显得拖沓。
            setInteger(MediaFormat.KEY_FRAME_RATE, fps.coerceIn(1, 144))
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    if (codec.codecInfo.getCapabilitiesForType(mime)
                            .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                        setInteger(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency, 1)
                    }
                } catch (_: Exception) { }
            }
        }
        codec.configure(format, surface, null, 0)
        codec.start()
        running.set(true)
        thread.start()
    }

    fun submit(frame: Frame): Boolean = queue.offer(frame)

    /** 供死亡检测用：累计提交进解码器的帧数 */
    fun snapshotInputCount(): Long = inputSubmitted

    fun release() {
        running.set(false)
        thread.interrupt()
        try { thread.join(500) } catch (_: InterruptedException) { }
        try { codec.stop() } catch (_: Exception) { }
        try { codec.release() } catch (_: Exception) { }
    }

    private fun loop() {
        val info = MediaCodec.BufferInfo()
        var statInput = 0L
        var statInputOk = 0L
        var statOutput = 0L
        var lastStatLog = 0L
        var lastLoggedInput = 0L
        var lastLoggedOutput = 0L
        var pendingFrame: Frame? = null
        while (running.get()) {
            try {
                // 静态画面不应让每块屏每 10ms 空转一次。50ms 只影响“完全无输入”
                // 时的尾部输出检查；有视频帧时 offer 会使 poll 立即返回。
                val frame = pendingFrame ?: queue.poll(IDLE_INPUT_WAIT_MS, TimeUnit.MILLISECONDS)
                var submittedInput = false
                if (frame != null) {
                    if (pendingFrame == null) statInput++
                    val inIdx = codec.dequeueInputBuffer(INPUT_BUFFER_WAIT_US)
                    if (inIdx >= 0) {
                        pendingFrame = null
                        statInputOk++
                        val buf = codec.getInputBuffer(inIdx)!!
                        buf.clear()
                        if (buf.remaining() >= frame.data.size) {
                            buf.put(frame.data)
                            // MediaCodec 依赖单调递增 PTS 释放输出缓冲；全零会被无限 hold
                            val pts = ptsIndex * frameDurationUs
                            ptsIndex++
                            codec.queueInputBuffer(inIdx, 0, frame.data.size, pts,
                                if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                            inputSubmitted++
                            submittedInput = true
                        } else {
                            Log.w(TAG, "frame too large for input buffer (${frame.data.size}), dropped")
                            codec.queueInputBuffer(inIdx, 0, 0, 0, 0)
                        }
                    } else {
                        // 这是已经编码完成的依赖帧，不能因 MediaCodec 暂时没空位就丢。
                        // 保留为 pending，先不从 FIFO 取下一帧；若外层队列随后填满，
                        // submit 会显式失败并让 FrameAssembler 请求 IDR。
                        pendingFrame = frame
                        Thread.sleep(2)
                    }
                }

                // 输出：聚合同批所有可用帧，只渲染最新
                var idx = codec.dequeueOutputBuffer(
                    info, if (submittedInput) OUTPUT_WAIT_AFTER_INPUT_US else 0)
                if (idx >= 0) {
                    while (true) {
                        val next = codec.dequeueOutputBuffer(info, 0)
                        if (next < 0) break
                        codec.releaseOutputBuffer(idx, false)
                        idx = next
                    }
                    codec.releaseOutputBuffer(idx, true)
                    renderedFrames++
                    statOutput++
                }
                val now = System.currentTimeMillis()
                if (now - lastStatLog > 10_000 &&
                    (statInput != lastLoggedInput || statOutput != lastLoggedOutput)) {
                    lastStatLog = now
                    lastLoggedInput = statInput
                    lastLoggedOutput = statOutput
                    Log.i(TAG, "stats in=$statInput inOk=$statInputOk out=$statOutput rendered=$renderedFrames")
                }
            } catch (e: Exception) {
                if (running.get()) Log.e(TAG, "decode loop error", e)
            }
        }
    }
}
