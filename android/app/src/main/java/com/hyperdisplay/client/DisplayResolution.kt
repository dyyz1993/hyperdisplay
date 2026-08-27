package com.hyperdisplay.client

/**
 * 副屏的像素档位只描述当前 Android 设备要请求的虚拟屏尺寸，不能拿来保存 UI 字号，
 * 更不能从另一台设备继承。0 表示按本机当前原生画布请求。
 */
internal object DisplayResolution {
    const val NATIVE = 0
    val supportedLongEdges = setOf(NATIVE, 1440, 1600, 1920, 2240)

    fun normalize(longEdge: Int): Int = longEdge.takeIf { it in supportedLongEdges } ?: NATIVE

    /** 只用于跨端展示/恢复，不影响已有的像素档位兼容值。 */
    fun presetId(longEdge: Int): Int = when (normalize(longEdge)) {
        NATIVE -> 0
        1440 -> 1
        1600 -> 2
        1920 -> 3
        else -> 4
    }

    fun label(longEdge: Int): String = when (normalize(longEdge)) {
        NATIVE -> "原生"
        1440 -> "特大"
        1600 -> "大"
        1920 -> "标准"
        else -> "紧凑"
    }

    /** 归一成横屏画布。调用方负责传入设备在沉浸式后的稳定可用画布。 */
    fun landscapeCanvas(width: Int, height: Int): Pair<Int, Int> =
        maxOf(width, height) to minOf(width, height)

    /** Host 创建 CGVirtualDisplay 前的统一 16px 对齐规则。 */
    fun hostAligned(width: Int, height: Int): Pair<Int, Int> {
        fun aligned(value: Int, minimum: Int) = (((value + 15) and 15.inv()).coerceAtLeast(minimum))
        return aligned(width, 640) to aligned(height, 480)
    }

    fun scale(width: Int, height: Int, deviceCanvasLongEdge: Int, longEdge: Int): Pair<Int, Int> {
        val normalized = normalize(longEdge)
        if (normalized == NATIVE) return width to height
        val sourceLongEdge = deviceCanvasLongEdge.coerceAtLeast(1)
        val scale = normalized.toFloat() / sourceLongEdge.toFloat()
        fun aligned(value: Int) = (((value * scale).toInt() + 15) and 15.inv()).coerceAtLeast(640)
        return aligned(width) to aligned(height)
    }
}
