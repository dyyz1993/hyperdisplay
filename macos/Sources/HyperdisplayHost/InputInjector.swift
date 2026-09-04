import Foundation
import CoreGraphics
import AppKit

/// 触控远控的 CGEvent 注入。2026-08-25 曾随「纯外置显示器」收敛整体移除，
/// 2026-09-04 恢复触控远控时从 git 历史复活，并修掉旧版两个缺陷：
/// ① 坐标映射改为调用方按当前 outputWidth/Height 现算——旧版缓存映射会在
///   档位切换/屏重排后悄悄过期，把点击落到错误的缩放位置；
/// ② 滚轮事件不带坐标、作用于真实光标所在窗口——旧版算了触点却丢弃，双指滚动
///   会滚到 Mac 主屏光标悬停的窗口；现在先定位再滚。
/// 在 UDP 接收线程调用；CGEvent post 线程安全。注入前必须已过辅助功能 TCC。
final class InputInjector {
    private let lock = NSLock()
    private var leftDown = false
    private var rightDown = false
    private var middleDown = false

    private func postMouseEvent(type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    func move(to point: CGPoint) {
        lock.lock()
        let dragging: CGEventType
        if leftDown { dragging = .leftMouseDragged }
        else if rightDown { dragging = .rightMouseDragged }
        else if middleDown { dragging = .otherMouseDragged }
        else { dragging = .mouseMoved }
        lock.unlock()
        postMouseEvent(type: dragging, at: point)
    }

    /// button：0=左 1=右 2=中（2 为平板三指手势新增，旧协议注释只写了 0/1）。
    func button(_ raw: UInt8, down: Bool, at point: CGPoint) {
        let mouseButton: CGMouseButton
        let type: CGEventType
        switch raw {
        case 1:
            mouseButton = .right
            type = down ? .rightMouseDown : .rightMouseUp
        case 2:
            mouseButton = .center
            type = down ? .otherMouseDown : .otherMouseUp
        default:
            mouseButton = .left
            type = down ? .leftMouseDown : .leftMouseUp
        }
        lock.lock()
        switch raw {
        case 1: rightDown = down
        case 2: middleDown = down
        default: leftDown = down
        }
        lock.unlock()
        postMouseEvent(type: type, at: point, button: mouseButton, clickState: 1)
    }

    // MARK: 滚动方向（跟随 Mac「自然滚动」偏好）

    private var naturalScrollCache: Bool?
    private var naturalScrollCheckedAt = Date.distantPast

    /// Mac 的「自然滚动」设置（com.apple.swipescrolldirection，默认开）。
    /// 合成滚轮事件不经过系统对物理 HID 输入的自然翻转，方向必须在这里自行对齐：
    /// 开=内容跟随手指（触控板习惯），关=传统鼠标（内容反向手指）。
    /// 平板手感因此始终与该 Mac 本机触控板一致；用户改系统设置后 5s 内跟进。
    /// 经 cfprefsd 读全局域（拿最新值），5s 缓存避免 60Hz 滚动流打爆 IPC。
    private func naturalScrolling() -> Bool {
        if let cached = naturalScrollCache,
           Date().timeIntervalSince(naturalScrollCheckedAt) < 5 { return cached }
        naturalScrollCheckedAt = Date()
        let raw = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                            kCFPreferencesAnyApplication) as? Bool
        let natural = raw ?? true // key 缺失 = 系统默认：自然滚动开
        naturalScrollCache = natural
        return natural
    }

    /// 滚轮：像素单位。倍率 2 为初始值，真机手感不对时再调。
    /// 方向按 Mac 自然滚动偏好适配（2026-09-04 用户实测：固定取负在自然滚动的
    /// Mac 上=内容反向手指，与触控板习惯相反）。
    func wheel(dx: Double, dy: Double, at point: CGPoint) {
        postMouseEvent(type: .mouseMoved, at: point)
        let gain = naturalScrolling() ? 1.0 : -1.0
        let intDx = Int32(max(-10_000, min(10_000, dx * 2 * gain)))
        let intDy = Int32(max(-10_000, min(10_000, dy * 2 * gain)))
        guard intDx != 0 || intDy != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: intDy, wheel2: intDx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
