import Foundation
import CoreGraphics
import HyperdisplayObjC

/// CGVirtualDisplay 的 Swift 包装。实际创建/销毁在 HyperdisplayObjC shim（ObjC 声明直接调用，
/// 避免 Swift @objc 协议符合性检查在私有类上失败的问题）。
/// 显示器实例由 shim 常驻持有；进程退出（含崩溃）时 windowserver 自动摘除全部虚拟屏。
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    /// 逻辑尺寸（点）：流输出/编码/UI 布局全用这个。当前生产配置固定为 1x。
    let logicalWidth: Int
    let logicalHeight: Int
    /// 系统回读像素尺寸，仅诊断/日志用。
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    /// 建屏时刻：起流沉降期判断（建屏瞬间起流的 SCK 概率性永不投递问题）
    let createdAt = Date()
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    /// hiDPI=0 是已验证的 1x 生产路径。非零值只供隔离实验；CGVirtualDisplay
    /// 当前无法提供真实 Retina 2x 语义。
    init?(width: Int, height: Int, refreshRate: Double = 60, productID: UInt32 = 0x0001,
          serial: UInt32 = 1, hiDPI: Int = 0) {
        let id = hyperdisplayCreateVirtualDisplay(UInt32(width), UInt32(height), refreshRate, "Hyperdisplay",
                                                   productID, serial, UInt8(hiDPI))
        guard id != 0 else {
            NSLog("[hyperdisplay] CGVirtualDisplay creation failed (id=0)")
            return nil
        }
        self.displayID = id
        self.logicalWidth = width
        self.logicalHeight = height
        if let mode = CGDisplayCopyDisplayMode(id) {
            self.pixelWidth = Int(mode.pixelWidth)
            self.pixelHeight = Int(mode.pixelHeight)
        } else {
            self.pixelWidth = width
            self.pixelHeight = height
        }
        let b = CGDisplayBounds(id)
        NSLog("[hyperdisplay] virtual display created: id=\(id) logical=\(width)x\(height) bounds=\(Int(b.width))x\(Int(b.height)) pixels=\(pixelWidth)x\(pixelHeight) hidpi=\(hiDPI) @\(refreshRate)Hz")
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
