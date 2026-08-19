import Foundation
import CoreGraphics
import HyperdisplayObjC

/// CGVirtualDisplay 的 Swift 包装。实际创建/销毁在 HyperdisplayObjC shim（ObjC 声明直接调用，
/// 避免 Swift @objc 协议符合性检查在私有类上失败的问题）。
/// 显示器实例由 shim 常驻持有；进程退出（含崩溃）时 windowserver 自动摘除全部虚拟屏。
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int

    /// - Parameters:
    ///   - width/height: **逻辑尺寸**。hiDPI=2 时物理像素为 2 倍（1400x920 → 2800x1840）
    ///   - hiDPI: 2 = macOS 2x 渲染（UI 常规大小 + 视网膜级文字锐度）；0 = 1x
    init?(width: Int, height: Int, refreshRate: Double = 60, serial: UInt32 = 1, hiDPI: Int = 0) {
        let id = hyperdisplayCreateVirtualDisplay(UInt32(width), UInt32(height), refreshRate, "Hyperdisplay", serial, UInt8(hiDPI))
        guard id != 0 else {
            NSLog("[hyperdisplay] CGVirtualDisplay creation failed (id=0)")
            return nil
        }
        self.displayID = id
        // 物理像素以系统回读为准（HiDPI 下 != 传入逻辑尺寸）
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
