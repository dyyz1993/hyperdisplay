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
 * - 输入侧容量 3 的最新帧队列（满则丢最旧——解码前丢帧，安全边界）；
 * - 输出侧一次吐多帧时只渲染最新，其余 release(false) 丢弃。
 */
class VideoDecoder(
    private val mime: String,
    private val width: Int,
    private val height: Int,
    private val surface: Surface,
    private val csd0: ByteArray
) {
    companion object {
        private const val TAG = "VideoDecoder"
    }

    class Frame(val keyframe: Boolean, val data: ByteArray)

    private val codec: MediaCodec = MediaCodec.createDecoderByType(mime)
    private val queue = ArrayBlockingQueue<Frame>(3)
    private val running = AtomicBoolean(false)
    private val thread = Thread({ loop() }, "hyperdisplay-decoder")
    private var ptsIndex = 0L
    @Volatile var renderedFrames: Int = 0
        private set

    fun start() {
        // KEY_CSD_0 在部分 SDK 中不对外导出，直接用其稳定字面值 "csd-0"
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd0))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 21)
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

    fun submit(frame: Frame): Boolean = queue.offer(frame) || run {
        queue.poll() // 丢最旧
        queue.offer(frame)
    }

    fun release() {
        running.set(false)
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
        while (running.get()) {
            try {
                val frame = queue.poll(10, TimeUnit.MILLISECONDS)
                if (frame != null) {
                    statInput++
                    val inIdx = codec.dequeueInputBuffer(10)
                    if (inIdx >= 0) {
                        statInputOk++
                        val buf = codec.getInputBuffer(inIdx)!!
                        buf.clear()
                        if (buf.remaining() >= frame.data.size) {
                            buf.put(frame.data)
                            // MediaCodec 依赖单调递增 PTS 释放输出缓冲；全零会被无限 hold
                            val pts = ptsIndex * 33_333L
                            ptsIndex++
                            codec.queueInputBuffer(inIdx, 0, frame.data.size, pts,
                                if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                        } else {
                            Log.w(TAG, "frame too large for input buffer (${frame.data.size}), dropped")
                            codec.queueInputBuffer(inIdx, 0, 0, 0, 0)
                        }
                    } else {
                        Thread.sleep(5) // 解码器输入拥堵，这一帧只能丢（最新帧已在队列顶部）
                    }
                }

                // 输出：聚合同批所有可用帧，只渲染最新
                var idx = codec.dequeueOutputBuffer(info, 0)
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
                if (now - lastStatLog > 3000) {
                    lastStatLog = now
                    Log.i(TAG, "stats in=$statInput inOk=$statInputOk out=$statOutput rendered=$renderedFrames")
                }
            } catch (e: Exception) {
                if (running.get()) Log.e(TAG, "decode loop error", e)
            }
        }
    }
}
