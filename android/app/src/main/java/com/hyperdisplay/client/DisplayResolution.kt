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

    /** Host 创建 CGVirtualDisplay 前的统一 16px 对齐规则。
     *  下限钳制必须按原始比例补偿另一维：窄高分屏的侧屏按比例只有 ~432px 宽，
     *  被抬到 640 下限后若高度不同步放大，宽高比从 0.457 断成 0.667——
     *  aspect-fit 只能上下留大黑边（2026-08-30 平板左右分屏实测）。 */
    fun hostAligned(width: Int, height: Int): Pair<Int, Int> {
        fun align16(value: Int) = (value + 15) and 15.inv()
        var w = align16(width).coerceAtLeast(640)
        var h = align16(height).coerceAtLeast(480)
        if (width in 1..639) h = maxOf(h, align16(w * height / width))
        if (height in 1..479) w = maxOf(w, align16(h * width / height))
        return w to h
    }

    fun scale(width: Int, height: Int, deviceCanvasLongEdge: Int, longEdge: Int): Pair<Int, Int> {
        val normalized = normalize(longEdge)
        if (normalized == NATIVE) return width to height
        val sourceLongEdge = deviceCanvasLongEdge.coerceAtLeast(1)
        val scale = normalized.toFloat() / sourceLongEdge.toFloat()
        return hostAligned((width * scale).toInt(), (height * scale).toInt())
    }
}
