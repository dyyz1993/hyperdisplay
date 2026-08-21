import Foundation
import CoreGraphics
import HyperdisplayObjC

/// CGVirtualDisplay 的 Swift 包装。实际创建/销毁在 HyperdisplayObjC shim（ObjC 声明直接调用，
/// 避免 Swift @objc 协议符合性检查在私有类上失败的问题）。
/// 显示器实例由 shim 常驻持有；进程退出（含崩溃）时 windowserver 自动摘除全部虚拟屏。
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    /// 逻辑尺寸（点）：流输出/编码/UI 布局全用这个。2x 屏的 pixelWidth 是它的一倍
    let logicalWidth: Int
    let logicalHeight: Int
    /// 物理像素（2x 屏 = 逻辑 × 2）。仅诊断/日志用
    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    /// 建屏时刻：起流沉降期判断（建屏瞬间起流的 SCK 概率性永不投递问题）
    let createdAt = Date()
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    /// - Parameters:
    ///   - width/height: **逻辑尺寸**（2x 渲染时 UI 常规大小，物理像素 ×2）
    ///   - hiDPI: 2 = 系统 2x 渲染（超采样：SCK 输出降到逻辑分辨率，文字更锐）；
    ///            0 = 1x（遗留，2x 屏上模式切换才生效，新代码一律用 2）
    init?(width: Int, height: Int, refreshRate: Double = 60, serial: UInt32 = 1, hiDPI: Int = 0) {
        let id = hyperdisplayCreateVirtualDisplay(UInt32(width), UInt32(height), refreshRate, "Hyperdisplay", serial, UInt8(hiDPI))
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

    /// 原地改分辨率（模式切换，身份/位置/窗口归属不变）。成功后 pixelWidth/Height
    /// 更新为系统回读值。显示大小档位切换专用——销毁重建会触发新 SCStream（必死）。
    func resize(width: Int, height: Int) -> Bool {
        guard hyperdisplayResizeVirtualDisplay(displayID, UInt32(width), UInt32(height)) else {
            return false
        }
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            pixelWidth = Int(mode.pixelWidth)
            pixelHeight = Int(mode.pixelHeight)
        }
        NSLog("[hyperdisplay] display \(displayID) resized to \(pixelWidth)x\(pixelHeight)")
        return true
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
