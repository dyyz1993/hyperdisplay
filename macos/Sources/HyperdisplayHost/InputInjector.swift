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

    private func postKey(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = modifiers
        up?.post(tap: .cghidEventTap)
    }

    // MARK: 系统动作（触控板默认手势的等效合成）

    /// 系统级手势（调度中心/切空间/启动台）不碰私有 gesture 事件，一律合成等效
    /// 动作：调度中心/切空间走系统默认全局快捷键（^↑ / ^← / ^→），启动台直接
    /// 打开 Launchpad.app（Sonoma+ 均为标准路径）。用户自定义过快捷键的机器上
    /// 以默认快捷键为准——自定义热键解析（symbolichotkeys）暂不支持。
    func performAction(_ raw: UInt8) {
        switch RemoteAction(rawValue: raw) {
        case .missionControl:
            postKey(keyCode: 126, modifiers: .maskControl) // ↑
        case .spaceLeft:
            postKey(keyCode: 123, modifiers: .maskControl) // ←
        case .spaceRight:
            postKey(keyCode: 124, modifiers: .maskControl) // →
        case .launchpad:
            // NSWorkspace 归 AppKit，回主线程调用。
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
            }
        case nil:
            break
        }
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
    /// 会话语义对齐触控板：作用点=会话开始时的光标位置（滚动期间不移动光标）；
    /// 事件带 scrollPhase（Began/Changed），抬手后由惯性引擎接力（见下）。
    func wheel(dx: Double, dy: Double, at point: CGPoint) {
        lock.lock()
        let beginSession = !scrollSessionActive
        var momentumWasActive = false
        if beginSession {
            scrollSessionActive = true
            scrollSampleWindow.removeAll()
            if momentumTimer != nil {
                momentumWasActive = true
                momentumTimer?.cancel()
                momentumTimer = nil
            }
        }
        lock.unlock()
        if momentumWasActive {
            // 惯性滚动中来了新滑动=用户急停：先给 app 一个 momentum End 归位状态机。
            postScrollEvent(dx: 0, dy: 0, scrollPhase: 0,
                            momentumPhase: ScrollPhase.momentumEnd)
        }
        if beginSession {
            postMouseEvent(type: .mouseMoved, at: point)
        }
        let gain = naturalScrolling() ? 1.0 : -1.0
        let contentDx = dx * 2 * gain
        let contentDy = dy * 2 * gain
        postScrollEvent(dx: contentDx, dy: contentDy,
                        scrollPhase: beginSession ? ScrollPhase.began : ScrollPhase.changed,
                        momentumPhase: 0)
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        scrollSampleWindow.append((t: now, dx: contentDx, dy: contentDy))
        while let first = scrollSampleWindow.first, now - first.t > 0.1 { scrollSampleWindow.removeFirst() }
        lock.unlock()
        scheduleLiftDetector()
    }

    // MARK: 触控板式惯性（2026-09-04）

    // 系统的 momentum 惯性引擎只伺候物理触控板；合成事件必须自带惯性序列：
    // 抬手（80ms 静默判定）后按指数衰减注入 momentumPhase Begin→Continue…→End。
    // 参数取接近 macOS 触控板观感的初值，真机手感不对再调。
    private static let liftSilence = 0.08     // 秒；wheel 包静默多久判定手指已抬
    private static let momentumMinSpeed = 200.0 // px/s；低于此速度抬手不产生惯性
    private static let momentumStopSpeed = 150.0 // px/s；衰减到此即发 End（120Hz 下每帧 ≥1px）
    private static let momentumTau = 0.35     // 指数衰减时间常数（秒）
    private static let momentumMaxDuration = 2.5 // 秒；保险上限
    private static let momentumHz = 120.0

    private let momentumQueue = DispatchQueue(label: "hyperdisplay.input-momentum")
    /// 仅在 UDP 接收线程读写（wheel 调用方），无需锁。 */
    private var liftDetector: DispatchWorkItem?
    private var scrollSessionActive = false
    private var scrollSampleWindow: [(t: Double, dx: Double, dy: Double)] = []
    private var momentumTimer: DispatchSourceTimer?

    /// CGEvent 滚动 phase 字段的公共 ABI 值（对应 kCGScrollEventPhase…/
    /// kCGScrollEventMomentumPhase… 常量：None/Begin=1、Changed/Continue=2、End=4）。
    private enum ScrollPhase {
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let momentumBegin: Int64 = 1
        static let momentumContinue: Int64 = 2
        static let momentumEnd: Int64 = 4
    }

    private func postScrollEvent(dx: Double, dy: Double, scrollPhase: Int64, momentumPhase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(max(-10_000, min(10_000, dy.rounded()))),
                                  wheel2: Int32(max(-10_000, min(10_000, dx.rounded()))),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }

    /// 每个滚轮包刷新一次：80ms 内无后续包视为手指已抬（无需改协议）。
    private func scheduleLiftDetector() {
        liftDetector?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scrollLifted() }
        liftDetector = item
        momentumQueue.asyncAfter(deadline: .now() + Self.liftSilence, execute: item)
    }

    private func scrollLifted() {
        lock.lock()
        guard scrollSessionActive else { lock.unlock(); return }
        scrollSessionActive = false
        let samples = scrollSampleWindow
        scrollSampleWindow.removeAll()
        lock.unlock()
        postScrollEvent(dx: 0, dy: 0, scrollPhase: ScrollPhase.ended, momentumPhase: 0)
        guard let first = samples.first, let last = samples.last else { return }
        let span = max(0.016, last.t - first.t)
        let vx = samples.reduce(0.0) { $0 + $1.dx } / span
        let vy = samples.reduce(0.0) { $0 + $1.dy } / span
        guard (vx * vx + vy * vy).squareRoot() >= Self.momentumMinSpeed else { return }
        startMomentum(vx: vx, vy: vy)
    }

    /// 衰减序列：v(t)=v0·e^(−t/τ)。vx/vy/elapsed 只在 momentumQueue 上访问，无需锁；
    /// momentumTimer 的创建/取消跨线程，由 lock 保护。
    private func startMomentum(vx: Double, vy: Double) {
        lock.lock()
        guard momentumTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: momentumQueue)
        var elapsed = 0.0
        let dt = 1.0 / Self.momentumHz
        var firstFrame = true
        let v0 = (vx * vx + vy * vy).squareRoot()
        timer.schedule(deadline: .now(), repeating: dt)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.momentumTimer == nil
            self.lock.unlock()
            guard !cancelled else { return }
            elapsed += dt
            let decay = exp(-elapsed / Self.momentumTau)
            if v0 * decay < Self.momentumStopSpeed || elapsed >= Self.momentumMaxDuration {
                self.postScrollEvent(dx: 0, dy: 0, scrollPhase: 0,
                                      momentumPhase: ScrollPhase.momentumEnd)
                self.lock.lock()
                if self.momentumTimer === timer { self.momentumTimer = nil }
                self.lock.unlock()
                return
            }
            let phase: Int64 = firstFrame ? ScrollPhase.momentumBegin
                                          : ScrollPhase.momentumContinue
            firstFrame = false
            self.postScrollEvent(dx: vx * decay * dt, dy: vy * decay * dt,
                                 scrollPhase: 0, momentumPhase: phase)
        }
        momentumTimer = timer
        lock.unlock()
        timer.resume()
    }
}
