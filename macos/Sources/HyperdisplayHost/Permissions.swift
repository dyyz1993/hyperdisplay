import Foundation
import CoreGraphics
import ApplicationServices

enum Permissions {
    /// 屏幕录制（ScreenCaptureKit 采集必需）
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统弹窗；已授权返回 true。授权后需重启 app 生效。
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 辅助功能（触控远控的 CGEvent 注入必需）。与屏幕录制不同：TCC 授权热生效，
    /// 无需重启进程。
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }
}
