import Foundation
import CoreGraphics
import AppKit

/// 流坐标 → 虚拟屏全局坐标的线性映射 + CGEvent 注入。
/// 坐标全部 clamp 在虚拟屏 bounds 内。
final class InputInjector {
    private let lock = NSLock()
    private var bounds: CGRect = .zero
    private var streamWidth: Double = 1
    private var streamHeight: Double = 1
    private var leftDown = false
    private var rightDown = false

    func updateMapping(bounds: CGRect, streamWidth: Double, streamHeight: Double) {
        lock.lock()
        self.bounds = bounds
        self.streamWidth = max(1, streamWidth)
        self.streamHeight = max(1, streamHeight)
        lock.unlock()
    }

    private func mapToGlobal(x: Double, y: Double) -> CGPoint {
        lock.lock()
        defer { lock.unlock() }
        let px = bounds.minX + (x / streamWidth) * bounds.width
        let py = bounds.minY + (y / streamHeight) * bounds.height
        return CGPoint(
            x: min(max(px, bounds.minX), bounds.maxX - 0.5),
            y: min(max(py, bounds.minY), bounds.maxY - 0.5)
        )
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickCount: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 输入处理（UDP 接收线程调用）

    func move(x: Double, y: Double) {
        let point = mapToGlobal(x: x, y: y)
        lock.lock()
        let dragging: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        lock.unlock()
        postMouseEvent(type: dragging, at: point)
    }

    func button(_ raw: UInt8, down: Bool, x: Double, y: Double) {
        let point = mapToGlobal(x: x, y: y)
        let isLeft = raw == 0
        lock.lock()
        if isLeft { leftDown = down } else { rightDown = down }
        lock.unlock()
        let type: CGEventType
        if isLeft {
            type = down ? .leftMouseDown : .leftMouseUp
        } else {
            type = down ? .rightMouseDown : .rightMouseUp
        }
        postMouseEvent(type: type, at: point, button: isLeft ? .left : .right, clickCount: 1)
    }

    /// 滚轮：像素单位，「自然滚动」语义——内容跟随手指方向移动。
    /// 倍率 2 为初始值，真机手感不对时再调。
    func wheel(dx: Double, dy: Double, x: Double, y: Double) {
        _ = mapToGlobal(x: x, y: y) // 光标先定位到目标位置，保证落在正确的窗口
        let intDx = Int32(max(-10_000, min(10_000, -dx * 2)))
        let intDy = Int32(max(-10_000, min(10_000, -dy * 2)))
        guard intDx != 0 || intDy != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: intDy, wheel2: intDx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
