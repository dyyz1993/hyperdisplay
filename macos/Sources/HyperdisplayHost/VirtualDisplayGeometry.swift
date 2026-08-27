import Foundation

enum VirtualDisplayModeCompatibility: Equatable {
    case requested
    case incompatible
}

/// 把客户端请求的物理像素规格转换成 macOS 的逻辑点规格。
///
/// Retina 模式下，虚拟屏仍以客户端请求的完整像素采集/编码，但 WindowServer
/// 使用一半大小的逻辑画布排版 UI。这样 2800×1840 的平板对应 1400×920 点，
/// 字体大小舒适且每个逻辑点拥有 2×2 个物理像素。
struct VirtualDisplayGeometry: Equatable {
    /// CGVirtualDisplay 在当前支持范围内的最小逻辑模式。小于它时 applySettings
    /// 会成功返回但回读模式被系统改写，最终造成建屏失败/重试 churn。
    static let minimumLogicalWidth = 640
    static let minimumLogicalHeight = 480

    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let backingScale: Int

    init?(pixelWidth: Int, pixelHeight: Int, retina: Bool = true) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let supportsRetina = pixelWidth >= Self.minimumLogicalWidth * 2 &&
            pixelHeight >= Self.minimumLogicalHeight * 2
        let scale: Int
        if retina {
            // Retina 是严格请求：逻辑模式不足或奇数像素时直接拒绝，绝不把用户的
            // 高清选择悄悄变成 1x。标准模式才明确传 retina=false。
            guard supportsRetina, pixelWidth.isMultiple(of: 2), pixelHeight.isMultiple(of: 2) else { return nil }
            scale = 2
        } else { scale = 1 }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = pixelWidth / scale
        self.logicalHeight = pixelHeight / scale
        self.backingScale = scale
    }

    func modeCompatibility(actualLogicalWidth: Int, actualLogicalHeight: Int,
                           actualPixelWidth: Int, actualPixelHeight: Int) -> VirtualDisplayModeCompatibility {
        if actualLogicalWidth == logicalWidth,
           actualLogicalHeight == logicalHeight,
           actualPixelWidth == pixelWidth,
           actualPixelHeight == pixelHeight {
            return .requested
        }
        return .incompatible
    }
}
