import Foundation
import CoreGraphics
import HyperdisplayObjC

enum VirtualDisplayModeState {
    case unavailable
    case matching
    case mismatch(logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int)

    var diagnosticDescription: String {
        switch self {
        case .unavailable:
            return "current mode unavailable"
        case .matching:
            return "requested mode ready"
        case let .mismatch(logicalWidth, logicalHeight, pixelWidth, pixelHeight):
            return "actual logical=\(logicalWidth)x\(logicalHeight) pixels=\(pixelWidth)x\(pixelHeight)"
        }
    }
}

/// CGVirtualDisplay 的 Swift 包装。实际创建/销毁在 HyperdisplayObjC shim（ObjC 声明直接调用，
/// 避免 Swift @objc 协议符合性检查在私有类上失败的问题）。
/// 显示器实例由 shim 常驻持有；进程退出（含崩溃）时 windowserver 自动摘除全部虚拟屏。
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private let requestedGeometry: VirtualDisplayGeometry
    /// macOS 的逻辑尺寸（点），只用于 WindowServer 桌面布局和坐标换算。
    private(set) var logicalWidth: Int
    private(set) var logicalHeight: Int
    /// ScreenCaptureKit、VideoToolbox 和 Android 使用的完整物理像素尺寸。
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    /// 用户请求的像素档案，用于重连时判断是否同一显示器配置；系统实际 1x mode
    /// 可能因 CGVirtualDisplay 的缩放语义而更小，不能拿它覆盖档案身份。
    let requestedPixelWidth: Int
    let requestedPixelHeight: Int
    private(set) var backingScale: Int
    /// 建屏时刻：起流沉降期判断（建屏瞬间起流的 SCK 概率性永不投递问题）
    let createdAt = Date()
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    /// width/height 是客户端需要的物理像素。retina=true 必须得到真实 2x；不支持
    /// 的尺寸由调用方明确报告失败，不能自动改建为 1x。
    init?(width: Int, height: Int, name: String = "Hyperdisplay", refreshRate: Double = 60, productID: UInt32 = 0x0001,
          serial: UInt32 = 1, retina: Bool = true) {
        guard let geometry = VirtualDisplayGeometry(pixelWidth: width, pixelHeight: height, retina: retina) else {
            NSLog("[hyperdisplay] invalid virtual display geometry: pixels=\(width)x\(height) retina=\(retina)")
            TopologyTimeline.shared.record("virtual display rejected invalid geometry pixels=\(width)x\(height) retina=\(retina)")
            return nil
        }
        TopologyTimeline.shared.record("virtual display attempt logical=\(geometry.logicalWidth)x\(geometry.logicalHeight) pixels=\(geometry.pixelWidth)x\(geometry.pixelHeight) scale=\(geometry.backingScale)x")
        let id = hyperdisplayCreateVirtualDisplay(UInt32(geometry.pixelWidth), UInt32(geometry.pixelHeight),
                                                   UInt32(geometry.logicalWidth), UInt32(geometry.logicalHeight),
                                                   refreshRate, name, productID, serial)
        guard id != 0 else {
            NSLog("[hyperdisplay] CGVirtualDisplay creation failed (id=0)")
            TopologyTimeline.shared.record("virtual display shim returned id=0 logical=\(geometry.logicalWidth)x\(geometry.logicalHeight) pixels=\(geometry.pixelWidth)x\(geometry.pixelHeight)")
            return nil
        }

        self.displayID = id
        self.requestedGeometry = geometry
        self.logicalWidth = geometry.logicalWidth
        self.logicalHeight = geometry.logicalHeight
        self.pixelWidth = geometry.pixelWidth
        self.pixelHeight = geometry.pixelHeight
        self.requestedPixelWidth = geometry.pixelWidth
        self.requestedPixelHeight = geometry.pixelHeight
        self.backingScale = geometry.backingScale
        let b = CGDisplayBounds(id)
        // `applySettings` 返回时 WindowServer 经常尚未给出 currentMode。不能在这里
        // 阻塞主线程等待：模式发布依赖 AppKit 主循环继续运行。拓扑状态机会在后续
        // tick 异步验证同一个对象，期间绝不销毁重建。
        NSLog("[hyperdisplay] virtual display object created: id=\(id) requested logical=\(logicalWidth)x\(logicalHeight) bounds=\(Int(b.width))x\(Int(b.height)) pixels=\(pixelWidth)x\(pixelHeight) scale=\(backingScale)x @\(refreshRate)Hz")
    }

    deinit {
        hyperdisplayDestroyVirtualDisplay(displayID)
    }

    /// 显式销毁（不必等 deinit）
    func destroy() {
        hyperdisplayDestroyVirtualDisplay(displayID)
    }

    /// 该屏在全局桌面坐标系中的 frame（副屏原点可为负）
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// 非阻塞读取 WindowServer 当前模式。创建后短暂 unavailable 属于正常注册过程；
    /// 调用方只需保留对象并在下一次状态机 tick 再看，不能原地 sleep 或重建屏幕。
    var currentModeState: VirtualDisplayModeState {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return .unavailable }
        let actualLogicalWidth = Int(mode.width)
        let actualLogicalHeight = Int(mode.height)
        let actualPixelWidth = Int(mode.pixelWidth)
        let actualPixelHeight = Int(mode.pixelHeight)
        if actualLogicalWidth == logicalWidth,
           actualLogicalHeight == logicalHeight,
           actualPixelWidth == pixelWidth,
           actualPixelHeight == pixelHeight {
            return .matching
        }
        return .mismatch(logicalWidth: actualLogicalWidth, logicalHeight: actualLogicalHeight,
                         pixelWidth: actualPixelWidth, pixelHeight: actualPixelHeight)
    }

    /// 标准 1x 是用户明确选择的非 Retina 模式。某些 macOS 版本会把较大的虚拟模式
    /// 以一半的实际 1x 尺寸发布；只要逻辑和物理读回相同，即采纳实测值并让采集器/
    /// 客户端按实测尺寸工作。Retina 路径绝不能调用本函数。
    func adoptActualStandardOneXMode() -> Bool {
        guard backingScale == 1, let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
        let width = Int(mode.width), height = Int(mode.height)
        guard width > 0, height > 0, width == Int(mode.pixelWidth), height == Int(mode.pixelHeight) else {
            return false
        }
        logicalWidth = width
        logicalHeight = height
        pixelWidth = width
        pixelHeight = height
        return true
    }

    func listAllDisplays() -> String {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return "<CGGetActiveDisplayList failed>" }
        return (0..<Int(count)).map { i -> String in
            let id = ids[i]
            let b = CGDisplayBounds(id)
            let main = id == CGMainDisplayID() ? " [main]" : ""
            let virtual = id == displayID ? " [hyperdisplay]" : ""
            return "  #\(i) id=\(id) \(Int(b.width))x\(Int(b.height)) origin(\(Int(b.minX)),\(Int(b.minY)))\(main)\(virtual)"
        }.joined(separator: "\n")
    }
}
