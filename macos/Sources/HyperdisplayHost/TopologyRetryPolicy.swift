import Foundation

/// 每块屏的健康沉降按创建时刻计时。WindowServer 模式发布和 SCK 枚举属于这段
/// 沉降过程，不能在它们完成后重新开始计时，否则双屏会平白多等数秒。
enum TopologyTimingPolicy {
    static let postCreationHealthGate: TimeInterval = 2

    static func healthGateDeadline(createdAt: Date) -> Date {
        createdAt.addingTimeInterval(postCreationHealthGate)
    }
}

/// 把任意次数的同步重入合并成当前推进结束后的一次补跑。
struct TopologyAdvanceGate {
    private(set) var isAdvancing = false
    private var pending = false

    mutating func begin() -> Bool {
        guard !isAdvancing else {
            pending = true
            return false
        }
        isAdvancing = true
        return true
    }

    mutating func end() -> Bool {
        isAdvancing = false
        let shouldAdvanceAgain = pending
        pending = false
        return shouldAdvanceAgain
    }
}

/// 虚拟屏拓扑失败后的退避策略。
///
/// 第一次失败通常是 WindowServer / ScreenCaptureKit 刚完成注销或枚举的短暂竞态，
/// 可以在不增加 churn 的前提下快速补试一次；连续失败才按长窗口熔断。该策略不处理
/// ColorSync 异常，后者仍由 Host 的独立 5 分钟保护负责。
struct TopologyRetryPolicy {
    /// WindowServer/SCK 的首次枚举竞态通常数秒内恢复；20 秒会让用户误以为应用卡死。
    /// 仅快速补试一次，连续失败仍进入一分钟熔断，避免显示器 churn 风暴。
    static let firstRetryDelay: TimeInterval = 5
    static let sustainedFailureDelay: TimeInterval = 60

    private var failures: [UInt32: Int] = [:]
    private var notBefore: [UInt32: Date] = [:]

    mutating func deferRetry(for deviceId: UInt32, now: Date) -> Date {
        let count = failures[deviceId, default: 0] + 1
        failures[deviceId] = count
        let delay = count == 1 ? Self.firstRetryDelay : Self.sustainedFailureDelay
        let deadline = now.addingTimeInterval(delay)
        notBefore[deviceId] = deadline
        return deadline
    }

    func canAttempt(deviceId: UInt32, now: Date) -> Bool {
        now >= (notBefore[deviceId] ?? .distantPast)
    }

    mutating func reset(deviceId: UInt32) {
        failures.removeValue(forKey: deviceId)
        notBefore.removeValue(forKey: deviceId)
    }
}
