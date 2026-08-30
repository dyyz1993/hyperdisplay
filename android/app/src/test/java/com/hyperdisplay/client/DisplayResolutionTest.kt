package com.hyperdisplay.client

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayResolutionTest {
    @Test
    fun nativeKeepsEachDeviceOwnGeometry() {
        assertEquals(1400 to 1840, DisplayResolution.scale(1400, 1840, 2800, DisplayResolution.NATIVE))
        assertEquals(1072 to 1088, DisplayResolution.scale(1072, 1088, 2144, DisplayResolution.NATIVE))
    }

    @Test
    fun tierScalesOnlyTheCallingDevicesProfile() {
        // 平板左右第一屏：1400×1840 在 1440 长边档会降为 720×960。
        assertEquals(720 to 960, DisplayResolution.scale(1400, 1840, 2800, 1440))
        // 手机的 1072×1088 则按自己的画布独立缩放，绝不能得到平板的 720×960。
        assertEquals(720 to 736, DisplayResolution.scale(1072, 1088, 2144, 1440))
    }

    @Test
    fun unknownPersistedTierFallsBackToNative() {
        assertEquals(DisplayResolution.NATIVE, DisplayResolution.normalize(1337))
    }

    @Test
    fun stableUsableCanvasDefinesTheDisplayAspect() {
        // Redmi Note 7 的 MIUI 横屏稳定可用画布是 2131×1080；不能用物理 2340×1080
        // 去强迫渲染跨越系统保留的手势区，否则等比显示必然产生黑边。
        assertEquals(2131 to 1080, DisplayResolution.landscapeCanvas(1080, 2131))
        assertEquals(1065 to 1080, DisplayResolution.landscapeCanvas(1080, 2131).let {
            (width, height) -> width / 2 to height
        })
    }

    @Test
    fun hostAlignmentIsNotTreatedAsANewDisplayProfile() {
        assertEquals(1072 to 1088, DisplayResolution.hostAligned(1064, 1080))
        assertEquals(1072 to 1088, DisplayResolution.hostAligned(1066, 1080))
        // 下限钳制不破坏比例（2026-08-30 分屏侧屏黑边根因修复）：
        // 100x100 方形 → 宽抬 640，高按比例同抬 640；窄高侧屏 432x960 → 640x1424
        assertEquals(640 to 640, DisplayResolution.hostAligned(100, 100))
        assertEquals(640 to 1424, DisplayResolution.hostAligned(432, 960))
    }
}
