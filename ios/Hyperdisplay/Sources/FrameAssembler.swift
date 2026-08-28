import Foundation

/// 视频分片重组，latest-frame 策略（逐行对照 android/.../FrameAssembler.kt 移植）：
/// - 只重组当前最新的 frameId；更新的 frameId 到达即整体丢弃旧帧未完成分片；
/// - 检测到帧序号缺口（丢帧破坏依赖链）→ 进入「等待关键帧」状态，丢弃后续非关键帧，
///   限频请求 IDR；
/// - 当前帧分片停滞超时同样视为丢失处理。
///
/// 所有时间参数（毫秒）由调用方显式传入：生产路径用 HostSession 心跳节拍，
/// 单元测试可以直接推进虚拟时钟做确定性验证。
///
/// ⚠️ 回调纪律（真机 0x8BADF00D 血案，2026-08-29）：onFrame 回调会在同一线程
/// 重入本类（解码背压 → requireKeyframeAfterDecoderBackpressure）。安卓原版靠
/// synchronized 可重入侥幸存活；NSLock 不可重入，持锁期间直接发回调 = 主线程
/// 自死锁 → watchdog SIGKILL。因此**所有回调一律出锁后触发**：锁内只算状态与
/// 限频决策，动作收集进 Actions，解锁后再执行。
final class FrameAssembler {

    struct Callbacks {
        /// 完整 Annex-B 帧
        var onFrame: (Int64, Bool, Data) -> Void
        var onKeyframeNeeded: (String) -> Void
        /// 丢帧反馈：仅通知 host 拥塞；视频不重传旧分片。missing 恒为空（空 NACK 语义）。
        var onNackKeyframeFragments: (Int64, [UInt16]) -> Void
        var debugLog: (String) -> Void = { NSLog("FrameAssembler: %@", $0) }
    }

    /// 一次事件中需要触发的回调（在锁外执行）。
    private struct Actions {
        var deliver: (id: Int64, keyframe: Bool, data: Data)?
        var keyframeReasons: [String] = []
        var congestionReports: [(id: Int64, reason: String)] = []

        var isEmpty: Bool { deliver == nil && keyframeReasons.isEmpty && congestionReports.isEmpty }
    }

    private let callbacks: Callbacks

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    private var lastDeliveredFrameId = Int64(-1)
    private var currentFrameId = Int64(-1)
    private var currentFragCount = 0
    private var currentKeyframe = false
    private var fragments: [Data?] = []
    private var deliveredCurrent = false
    private var lastFragmentAtMs = UInt64(0)
    private var waitingForKeyframe = true   // 仅用于会话最初：第一帧必须是 IDR
    private var everGotKeyframe = false
    private var lastKeyframeRequestAtMs = UInt64(0)
    /// 整帧放弃的轻量反馈限流。空 NACK 表示拥塞，不代表“补 0 片”。
    private var lastCongestionReportAtMs = UInt64(0)
    private let lock = NSLock()

    static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    func onFragment(frameId: Int64, fragIdx: Int, fragCount: Int, keyframe: Bool,
                    payload: Data, nowMs now: UInt64? = nil) {
        perform(computeFragmentStep(frameId: frameId, fragIdx: fragIdx, fragCount: fragCount,
                                    keyframe: keyframe, payload: payload, now: now ?? Self.nowMs()))
    }

    /// 由外部周期调用（≥100ms 一次）：分片停滞检测
    func stallCheck(nowMs now: UInt64? = nil) {
        perform(computeStallCheck(now: now ?? Self.nowMs()))
    }

    /// host 重启/重连后调用
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastDeliveredFrameId = -1
        currentFrameId = -1
        fragments = []
        waitingForKeyframe = true
        everGotKeyframe = false
    }

    /// 已编码帧进不了解码 FIFO 时，后续 P 帧不能跨过缺口继续送硬解。
    /// 会从 onFrame 回调内同步重入（解码背压路径）——这正是回调必须出锁的原因。
    func requireKeyframeAfterDecoderBackpressure(frameId: Int64, nowMs now: UInt64? = nil) {
        var actions = Actions()
        lock.lock()
        let now = now ?? Self.nowMs()
        waitingForKeyframe = true
        if shouldReportCongestion(now) {
            actions.congestionReports.append((frameId, "decoder queue full"))
        }
        if shouldRequestKeyframe(now) {
            actions.keyframeReasons.append("decoder queue full at \(frameId)")
        }
        lock.unlock()
        perform(actions)
    }

    // MARK: - 状态机（锁内计算，不发回调）

    private func computeFragmentStep(frameId: Int64, fragIdx: Int, fragCount: Int, keyframe: Bool,
                                     payload: Data, now: UInt64) -> Actions {
        var actions = Actions()
        lock.lock()
        defer { lock.unlock() }

        if frameId < currentFrameId { return actions } // 过期分片
        if frameId > currentFrameId {
            // 起流/丢帧恢复时，正在接收的 IDR 是唯一能重建解码参考链的锚点。
            // 只在等 IDR 且当前 IDR 尚未完成时忽略后续非关键帧；更新的 IDR 仍可替换旧 IDR。
            if waitingForKeyframe && currentKeyframe && !deliveredCurrent &&
                !isComplete() && !keyframe {
                return actions
            }
            // 新帧开始；旧帧未投递且缺分片才视为丢弃（latest-frame policy）
            if currentFrameId >= 0 && !deliveredCurrent && !isComplete() {
                if currentKeyframe {
                    noteKeyframeAbandoned(into: &actions, now: now)
                } else if everGotKeyframe {
                    waitingForKeyframe = true
                    noteCongestion(into: &actions, frameId: currentFrameId,
                                   reason: "incomplete delta", now: now)
                    noteKeyframeRequest(into: &actions,
                                        reason: "incomplete delta \(currentFrameId)", now: now)
                }
            }
            if lastDeliveredFrameId >= 0 && frameId > lastDeliveredFrameId + 1 && everGotKeyframe {
                // HEVC 硬解对断引用 P 帧可能输出整帧绿色；宁可保留上一张画面等待干净 IDR，
                // 也不能把它送进解码器污染输出面。
                waitingForKeyframe = true
                noteCongestion(into: &actions, frameId: frameId, reason: "frame gap", now: now)
                noteKeyframeRequest(into: &actions,
                                    reason: "gap \(lastDeliveredFrameId) -> \(frameId)", now: now)
            }
            currentFrameId = frameId
            currentFragCount = fragCount
            currentKeyframe = keyframe
            deliveredCurrent = false
            fragments = Array<Data?>(repeating: nil, count: fragCount)
        }

        guard fragIdx < fragments.count else { return actions }
        lastFragmentAtMs = now
        if fragments[fragIdx] == nil { fragments[fragIdx] = payload }

        if isComplete() {
            var out = Data()
            out.reserveCapacity(fragments.reduce(0) { $0 + ($1?.count ?? 0) })
            for frag in fragments where frag != nil { out.append(frag!) }
            fragments = []
            deliveredCurrent = true
            lastDeliveredFrameId = frameId
            if waitingForKeyframe {
                if !keyframe {
                    return actions // 会话最初：解码器还没有任何参考帧，必须等 IDR
                }
                everGotKeyframe = true
                waitingForKeyframe = false
            }
            if keyframe { waitingForKeyframe = false }
            actions.deliver = (frameId, keyframe, out)
        }
        return actions
    }

    private func computeStallCheck(now: UInt64) -> Actions {
        var actions = Actions()
        lock.lock()
        defer { lock.unlock() }

        if currentFrameId < 0 {
            // 等关键帧但没有任何分片到达（如首帧全丢）：NACK 无从触发，周期性请求 IDR
            if waitingForKeyframe {
                noteKeyframeRequest(into: &actions, reason: "idle-wait", now: now)
            }
            return actions
        }
        if deliveredCurrent || isComplete() { return actions }
        let idle = Int(clamping: now &- lastFragmentAtMs)
        // 视频不补传：缺片的 IDR 已经过期，不能等秒级；仍给 Wi-Fi 短暂抖动和
        // Host 的 90ms 分片节流留出 250ms 乱序窗口。
        let patience: Int = 250
        if idle > patience {
            if currentKeyframe {
                noteKeyframeAbandoned(into: &actions, now: now)
            } else if everGotKeyframe {
                waitingForKeyframe = true
                noteCongestion(into: &actions, frameId: currentFrameId, reason: "delta stall", now: now)
            }
            currentFrameId = -1
            fragments = []
            if !everGotKeyframe { waitingForKeyframe = true }
            noteKeyframeRequest(into: &actions, reason: "stall \(idle)ms", now: now)
        }
        return actions
    }

    // MARK: - 内部

    private func isComplete() -> Bool {
        !fragments.isEmpty && fragments.allSatisfy { $0 != nil }
    }

    /// IDR 缺片被放弃：空 NACK（拥塞）+ 限频 IDR 请求。仅锁内调用。
    private func noteKeyframeAbandoned(into actions: inout Actions, now: UInt64) {
        let missing = fragments.filter { $0 == nil }.count
        noteCongestion(into: &actions, frameId: currentFrameId,
                       reason: "keyframe missing \(missing)", now: now)
        noteKeyframeRequest(into: &actions, reason: "discard stale keyframe \(currentFrameId)", now: now)
    }

    /// 空拥塞反馈限流（750ms）。仅锁内调用。
    private func noteCongestion(into actions: inout Actions, frameId: Int64, reason: String, now: UInt64) {
        guard shouldReportCongestion(now) else { return }
        actions.congestionReports.append((frameId, reason))
    }

    /// IDR 请求限流（500ms）：既不给关键帧在途制造请求风暴，也能在首次请求丢失时快速补救。
    private func noteKeyframeRequest(into actions: inout Actions, reason: String, now: UInt64) {
        guard shouldRequestKeyframe(now) else { return }
        actions.keyframeReasons.append(reason)
    }

    private func shouldReportCongestion(_ now: UInt64) -> Bool {
        if now &- lastCongestionReportAtMs < 750 { return false }
        lastCongestionReportAtMs = now
        return true
    }

    private func shouldRequestKeyframe(_ now: UInt64) -> Bool {
        if now &- lastKeyframeRequestAtMs < 500 { return false }
        lastKeyframeRequestAtMs = now
        return true
    }

    /// 回调统一出口（必须已出锁）。保持与旧实现一致的动作顺序：拥塞反馈 → IDR 请求 → 投递。
    private func perform(_ actions: Actions) {
        guard !actions.isEmpty else { return }
        for report in actions.congestionReports {
            callbacks.debugLog("receiver congested: \(report.reason)")
            callbacks.onNackKeyframeFragments(report.id, [])
        }
        for reason in actions.keyframeReasons {
            callbacks.debugLog("keyframe requested: \(reason)")
            callbacks.onKeyframeNeeded(reason)
        }
        if let deliver = actions.deliver {
            callbacks.onFrame(deliver.id, deliver.keyframe, deliver.data)
        }
    }
}
