package com.hyperdisplay.client

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class OverlayCoordinatesTest {
    @Test
    fun subtractsOverlayWindowOriginForInsetPhoneWindows() {
        // 子画面从窗口 y=84 开始，光标层从 y=24（状态栏 inset）开始；
        // 光标层坐标必须是 60+局部点，而不是错误的 84+局部点。
        assertArrayEquals(
            floatArrayOf(130f, 260f),
            mapPointToOverlay(
                pointX = 30f, pointY = 200f,
                viewWindowX = 100, viewWindowY = 84,
                overlayWindowX = 0, overlayWindowY = 24,
            ),
            0.001f,
        )
    }

    @Test
    fun keepsTabletCoordinatesWhenBothOriginsMatch() {
        assertArrayEquals(
            floatArrayOf(640f, 360f),
            mapPointToOverlay(
                pointX = 640f, pointY = 360f,
                viewWindowX = 0, viewWindowY = 0,
                overlayWindowX = 0, overlayWindowY = 0,
            ),
            0.001f,
        )
    }
}
