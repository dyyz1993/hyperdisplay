import Foundation
import CoreGraphics

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
}
