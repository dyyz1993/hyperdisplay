package com.hyperdisplay.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameAssemblerTest {
    @Test
    fun incompleteRecoveryKeyframeIsNotPreemptedByLaterDeltaFrame() {
        val delivered = mutableListOf<Int>()
        val assembler = FrameAssembler(object : FrameAssembler.Callback {
            override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) {
                delivered += frameId
            }

            override fun onKeyframeNeeded(reason: String) = Unit

            override fun onNackKeyframeFragments(frameId: Int, missing: List<Int>) = Unit
        }, debugLog = {})

        assembler.onFragment(10, 0, 2, true, byteArrayOf(1))
        assembler.onFragment(11, 0, 1, false, byteArrayOf(2))
        assembler.onFragment(10, 1, 2, true, byteArrayOf(3))

        assertEquals(listOf(10), delivered)
    }

    @Test
    fun decoderBackpressureDropsDependentFramesUntilNextKeyframe() {
        val delivered = mutableListOf<Int>()
        val keyframeReasons = mutableListOf<String>()
        val congestionFrames = mutableListOf<Int>()
        val assembler = FrameAssembler(object : FrameAssembler.Callback {
            override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) {
                delivered += frameId
            }

            override fun onKeyframeNeeded(reason: String) {
                keyframeReasons += reason
            }

            override fun onNackKeyframeFragments(frameId: Int, missing: List<Int>) {
                congestionFrames += frameId
            }
        }, debugLog = {})

        assembler.onFragment(1, 0, 1, true, byteArrayOf(1))
        assembler.onFragment(2, 0, 1, false, byteArrayOf(2))
        assembler.requireKeyframeAfterDecoderBackpressure(2)
        assembler.onFragment(3, 0, 1, false, byteArrayOf(3))
        assembler.onFragment(4, 0, 1, true, byteArrayOf(4))

        assertEquals(listOf(1, 2, 4), delivered)
        assertTrue(keyframeReasons.any { it.contains("decoder queue full") })
        assertEquals(listOf(2), congestionFrames)
    }

    // ── FEC 校验恢复（2026-08-29，对照 iOS FrameAssemblerTests）──

    private fun feedParity(assembler: FrameAssembler, frameId: Int, chunks: List<ByteArray>) {
        val groupSize = FrameAssembler.FEC_GROUP_SIZE
        for (g in 0 until (chunks.size + groupSize - 1) / groupSize) {
            val start = g * groupSize
            val end = minOf(start + groupSize, chunks.size)
            var maxLen = 0
            for (i in start until end) maxLen = maxOf(maxLen, chunks[i].size)
            val xor = ByteArray(maxLen)
            for (i in start until end) {
                val c = chunks[i]
                for (j in c.indices) xor[j] = (xor[j].toInt() xor c[j].toInt()).toByte()
            }
            val payload = ByteArray(maxLen + 1 + 2 * (end - start))
            System.arraycopy(xor, 0, payload, 0, maxLen)
            payload[maxLen] = (end - start).toByte()
            for (i in start until end) {
                payload[maxLen + 1 + 2 * (i - start)] = (chunks[i].size and 0xFF).toByte()
                payload[maxLen + 2 + 2 * (i - start)] = ((chunks[i].size shr 8) and 0xFF).toByte()
            }
            assembler.onParityFragment(frameId, g, payload)
        }
    }

    @Test
    fun parityRecoversSingleLostFragment() {
        val delivered = mutableListOf<Int>()
        val payloads = mutableListOf<ByteArray>()
        val assembler = FrameAssembler(object : FrameAssembler.Callback {
            override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) {
                delivered += frameId; payloads += data
            }
            override fun onKeyframeNeeded(reason: String) = Unit
            override fun onNackKeyframeFragments(frameId: Int, missing: List<Int>) = Unit
        }, debugLog = {})
        // 9 片跨三组，末片长度不同（验证真实长度截断）
        val chunks = (0 until 9).map { i ->
            ByteArray(if (i == 8) 37 else 100) { (if (i == 8) 99 else i + 1).toByte() }
        }
        for (i in chunks.indices) {
            if (i != 5) assembler.onFragment(7, i, chunks.size, true, chunks[i])
        }
        feedParity(assembler, 7, chunks)

        assertEquals(listOf(7), delivered)
        val expected = ByteArray(chunks.sumOf { it.size })
        var off = 0
        chunks.forEach { System.arraycopy(it, 0, expected, off, it.size); off += it.size }
        assertTrue(payloads.first().contentEquals(expected))
    }

    @Test
    fun parityCannotRecoverTwoLostInSameGroup() {
        val delivered = mutableListOf<Int>()
        val keyframeReasons = mutableListOf<String>()
        val assembler = FrameAssembler(object : FrameAssembler.Callback {
            override fun onFrame(frameId: Int, keyframe: Boolean, data: ByteArray) { delivered += frameId }
            override fun onKeyframeNeeded(reason: String) { keyframeReasons += reason }
            override fun onNackKeyframeFragments(frameId: Int, missing: List<Int>) = Unit
        }, debugLog = {})
        val chunks = (0 until 6).map { i -> ByteArray(50) { i.toByte() } }
        // 同组丢两片（1、2）：无法恢复
        for (i in chunks.indices) {
            if (i != 1 && i != 2) assembler.onFragment(9, i, chunks.size, true, chunks[i])
        }
        feedParity(assembler, 9, chunks)

        assertTrue(delivered.isEmpty())
        // 不可恢复由停滞检测收尾——生产路径是 200ms 心跳，这里手动推进不了时钟，
        // 但同组双丢后校验片不应错误地"恢复"出假数据（delivered 为空即证明）
    }
}
