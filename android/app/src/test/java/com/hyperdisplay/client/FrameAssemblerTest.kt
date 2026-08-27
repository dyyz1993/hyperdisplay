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
}
