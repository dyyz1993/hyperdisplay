import Foundation

/// 视频分片重组，latest-frame 策略（逐行对照 android/.../FrameAssembler.kt 移植）：
/// - 只重组当前最新的 frameId；更新的 frameId 到达即整体丢弃旧帧未完成分片；
/// - 检测到帧序号缺口（丢帧破坏依赖链）→ 进入「等待关键帧」状态，丢弃后续非关键帧，
///   限频请求 IDR；
/// - 当前帧分片停滞超时同样视为丢失处理。
///
/// 所有时间参数（毫秒）由调用方显式传入：生产路径用 HostSession 心跳节拍，
/// 单元测试可以直接推进虚拟时钟做确定性验证。
final class FrameAssembler {

    struct Callbacks {
        /// 完整 Annex-B 帧
        var onFrame: (Int64, Bool, Data) -> Void
        var onKeyframeNeeded: (String) -> Void
        /// 丢帧反馈：仅通知 host 拥塞；视频不重传旧分片。missing 恒为空（空 NACK 语义）。
        var onNackKeyframeFragments: (Int64, [UInt16]) -> Void
        var debugLog: (String) -> Void = { NSLog("FrameAssembler: %@", $0) }
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
        lock.lock()
        defer { lock.unlock() }
        let now = now ?? Self.nowMs()

        if frameId < currentFrameId { return } // 过期分片
        if frameId > currentFrameId {
            // 起流/丢帧恢复时，正在接收的 IDR 是唯一能重建解码参考链的锚点。
            // 只在等 IDR 且当前 IDR 尚未完成时忽略后续非关键帧；更新的 IDR 仍可替换旧 IDR。
            if waitingForKeyframe && currentKeyframe && !deliveredCurrent &&
                !isComplete() && !keyframe {
                return
            }
            // 新帧开始；旧帧未投递且缺分片才视为丢弃（latest-frame policy）
            if currentFrameId >= 0 && !deliveredCurrent && !isComplete() {
                onAbandoned()
                if currentKeyframe {
                    abandonKeyframe(currentFrameId, now)
                } else if everGotKeyframe {
                    waitingForKeyframe = true
                    reportCongestionRateLimited(currentFrameId, "incomplete delta", now)
                    requestKeyframeRateLimited("incomplete delta \(currentFrameId)", now)
                }
            }
            if lastDeliveredFrameId >= 0 && frameId > lastDeliveredFrameId + 1 && everGotKeyframe {
                // HEVC 硬解对断引用 P 帧可能输出整帧绿色；宁可保留上一张画面等待干净 IDR，
                // 也不能把它送进解码器污染输出面。
                waitingForKeyframe = true
                reportCongestionRateLimited(frameId, "frame gap", now)
                requestKeyframeRateLimited("gap \(lastDeliveredFrameId) -> \(frameId)", now)
            }
            currentFrameId = frameId
            currentFragCount = fragCount
            currentKeyframe = keyframe
            deliveredCurrent = false
            fragments = Array<Data?>(repeating: nil, count: fragCount)
        }

        guard fragIdx < fragments.count else { return }
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
                    onAbandoned()
                    return // 会话最初：解码器还没有任何参考帧，必须等 IDR
                }
                everGotKeyframe = true
                waitingForKeyframe = false
            }
            if keyframe { waitingForKeyframe = false }
            callbacks.onFrame(frameId, keyframe, out)
        }
    }

    /// 由外部周期调用（≥100ms 一次）：分片停滞检测
    func stallCheck(nowMs now: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = now ?? Self.nowMs()

        if currentFrameId < 0 {
            // 等关键帧但没有任何分片到达（如首帧全丢）：NACK 无从触发，周期性请求 IDR
            if waitingForKeyframe { requestKeyframeRateLimited("idle-wait", now) }
            return
        }
        if deliveredCurrent || isComplete() { return }
        let idle = Int(clamping: now &- lastFragmentAtMs)
        // 视频不补传：缺片的 IDR 已经过期，不能等秒级；仍给 Wi-Fi 短暂抖动和
        // Host 的 90ms 分片节流留出 250ms 乱序窗口。
        let patience: Int = 250
        if idle > patience {
            onAbandoned()
            if currentKeyframe {
                abandonKeyframe(currentFrameId, now)
            } else if everGotKeyframe {
                waitingForKeyframe = true
                reportCongestionRateLimited(currentFrameId, "delta stall", now)
            }
            currentFrameId = -1
            fragments = []
            if !everGotKeyframe { waitingForKeyframe = true }
            requestKeyframeRateLimited("stall \(idle)ms", now)
        }
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
    func requireKeyframeAfterDecoderBackpressure(frameId: Int64, nowMs now: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = now ?? Self.nowMs()
        waitingForKeyframe = true
        reportCongestionRateLimited(frameId, "decoder queue full", now)
        requestKeyframeRateLimited("decoder queue full at \(frameId)", now)
    }

    // MARK: - 内部

    private func isComplete() -> Bool {
        !fragments.isEmpty && fragments.allSatisfy { $0 != nil }
    }

    private func abandonKeyframe(_ frameId: Int64, _ now: UInt64) {
        let missing = fragments.enumerated().filter { $0.element == nil }.map { $0.offset }
        reportCongestionRateLimited(frameId, "keyframe missing \(missing.count)", now)
        requestKeyframeRateLimited("discard stale keyframe \(frameId)", now)
    }

    private func reportCongestionRateLimited(_ frameId: Int64, _ reason: String, _ now: UInt64) {
        if now &- lastCongestionReportAtMs < 750 { return }
        lastCongestionReportAtMs = now
        callbacks.debugLog("receiver congested: \(reason)")
        callbacks.onNackKeyframeFragments(frameId, [])
    }

    private func onAbandoned() {
        // latest-frame 的正常工作就是大量放弃过期帧，不打日志避免抢解码线程。
    }

    private func requestKeyframeRateLimited(_ reason: String, _ now: UInt64) {
        // 500ms 既不给关键帧在途制造请求风暴，也能在首次请求丢失时快速补救。
        if now &- lastKeyframeRequestAtMs < 500 { return }
        lastKeyframeRequestAtMs = now
        callbacks.debugLog("keyframe requested: \(reason)")
        callbacks.onKeyframeNeeded(reason)
    }
}
