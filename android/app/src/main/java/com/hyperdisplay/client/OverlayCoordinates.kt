package com.hyperdisplay.client

/**
 * 把子视图中的点换算到同一窗口内的叠加层坐标。
 *
 * `getLocationInWindow` 的原点是 Android 窗口，而本地光标是 root 内的子 View；
 * 手机在状态栏、挖孔或导航栏参与布局时，两者原点不一定重合。直接使用子视图的
 * window 坐标会让叠加光标稳定向下/向右偏移。
 */
internal fun mapPointToOverlay(
    pointX: Float,
    pointY: Float,
    viewWindowX: Int,
    viewWindowY: Int,
    overlayWindowX: Int,
    overlayWindowY: Int,
): FloatArray = floatArrayOf(
    viewWindowX + pointX - overlayWindowX,
    viewWindowY + pointY - overlayWindowY,
)
