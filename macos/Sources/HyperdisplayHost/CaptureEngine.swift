import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import IOSurface

/// 只采集指定 displayID 的 SCStream。虚拟屏创建后可能要等一小会儿才会出现在
/// SCShareableContent 里，start() 内部带轮询。
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// 强制关键帧时重放最近 IOSurface；它不是新的桌面内容，不能拿来重新触发
    /// “动→静”检测，否则静态锐化会把自己误判成持续运动。
    var onReplayFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private let lock = NSLock()
    private var captureWidth = 0
    private var captureHeight = 0
    private var desiredFrameRate = 60
    private var appliedFrameRate = 60
    private var configurationUpdateInFlight = false
    private(set) var capturedFrames: UInt64 = 0
    private var lastFrame: CVPixelBuffer?
    private var statusCounts: [Int: Int] = [:]
    private var loggedEvents = 0
    private(set) var buffersSeen: UInt64 = 0
    /// 最近一次收到任意 SCK 事件（含 idle）的时间：供停流看门狗判断流是否静默
    private(set) var lastEventAt: Date?
    /// idle 帧判新：macOS 26 某些构建上内容更新只走 idle 通道（complete 恒无
    /// buffer，2026-08-21 重启后 100% 复现）。通常新内容 = 新 IOSurface；但
    /// macOS 26 也会复用同一 surface、只推进 seed。**不可用
    /// LockBaseAddress 采样像素**——对 SCK 的 IOSurface buffer 会死锁事件线程
    /// （实测每个实例在首个 idle 帧后冻结）。
    private var lastIdleSurfaceID: UInt32 = 0
    /// 不读取像素就能识别同一 IOSurface 上的新内容，避免 LockBaseAddress 在 SCK
    /// 事件线程死锁；否则平板会一直显示旧帧，尽管 Host 原始桌面已经变了。
    private var lastIdleSurfaceSeed: UInt32 = 0

    /// 把最近一帧重新送编码（配合 force keyframe），用于客户端中途加入/重连时
    /// 静态桌面不出新帧的场景——否则 PLI 永远等不到新源帧。
    func replayLastFrame() {
        lock.lock()
        let frame = lastFrame
        lock.unlock()
        if let frame {
            NSLog("[hyperdisplay] replaying last captured frame for forced keyframe")
            (onReplayFrame ?? onFrame)?(frame)
        } else {
            NSLog("[hyperdisplay] replay requested but no buffered frame yet")
        }
    }

    deinit {
        NSLog("[hyperdisplay] CaptureEngine dealloc (display %u)", displayID)
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        self.displayID = displayID
        let content = try await waitForDisplay(displayID: displayID)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw HostError("display \(displayID) not visible to ScreenCaptureKit")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = Self.makeConfiguration(width: width, height: height, fps: fps)

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()
        lock.lock()
        self.stream = stream
        captureWidth = width
        captureHeight = height
        desiredFrameRate = max(1, fps)
        appliedFrameRate = max(1, fps)
        configurationUpdateInFlight = false
        lastIdleSurfaceID = 0
        lastIdleSurfaceSeed = 0
        lastEventAt = Date() // 起始锚点：刚启动时 idle 事件可能要几十 ms 才到
        lock.unlock()
        NSLog("[hyperdisplay] capture started for display %u (%dx%d@%d)", displayID, width, height, fps)
    }

    /// 同一流对象重启（stopCapture→startCapture）。SCK 经 churn 后新建流偶发
    /// 永久静默，而原流 stop→start 可恢复；因此当前显示器生命周期内看门狗
    /// 始终复用原 SCStream，不升级为重建屏。
    func restart() async throws {
        lock.lock()
        let s = stream
        lastEventAt = Date()
        lastIdleSurfaceID = 0
        lastIdleSurfaceSeed = 0
        lock.unlock()
        guard let s else { throw HostError("restart on stopped engine") }
        try? await s.stopCapture()
        try await s.startCapture()
        NSLog("[hyperdisplay] capture restarted (same SCStream)")
    }

    func stop() {
        lock.lock()
        let s = stream
        stream = nil
        configurationUpdateInFlight = false
        lastFrame = nil // 释放持有的 IOSurface（属于旧流，跨流持有会卡 SCK 表面池）
        lock.unlock()
        guard let s else { return }
        s.stopCapture()
        // 必须显式摘除输出：SCStream 强持有 output 回调，不摘会留下僵尸流，
        // 放大后续新流静默概率。
        try? s.removeStreamOutput(self, type: .screen)
    }

    /// 运行中只调整 SCK 的最大回调频率，不重建 SCStream，更不触碰虚拟屏。
    /// 静止时降到 30fps 可减少 WindowServer 合成/采集唤醒；真实内容一出现就恢复
    /// 会话帧率。更新串行化，避免“静止降档”和“开始滚动升档”并发覆盖配置。
    func requestFrameRate(_ fps: Int) {
        let requested = max(1, fps)
        lock.lock()
        desiredFrameRate = requested
        guard stream != nil,
              !configurationUpdateInFlight,
              appliedFrameRate != desiredFrameRate else {
            lock.unlock()
            return
        }
        configurationUpdateInFlight = true
        let target = desiredFrameRate
        let width = captureWidth
        let height = captureHeight
        let activeStream = stream
        lock.unlock()

        guard let activeStream else { return }
        let cfg = Self.makeConfiguration(width: width, height: height, fps: target)
        Task { [weak self] in
            do {
                try await activeStream.updateConfiguration(cfg)
                self?.finishFrameRateUpdate(target: target, succeeded: true)
            } catch {
                NSLog("[hyperdisplay] capture frame-rate update failed display=%u target=%d: %@",
                      self?.displayID ?? 0, target, error.localizedDescription)
                self?.finishFrameRateUpdate(target: target, succeeded: false)
            }
        }
    }

    private func finishFrameRateUpdate(target: Int, succeeded: Bool) {
        lock.lock()
        if succeeded { appliedFrameRate = target }
        configurationUpdateInFlight = false
        if !succeeded, desiredFrameRate == target {
            // 当前请求失败时保留已生效值，不做无休止重试；下一次动静转换会再尝试。
            desiredFrameRate = appliedFrameRate
        }
        let followUp = stream != nil && desiredFrameRate != appliedFrameRate
        let desired = desiredFrameRate
        lock.unlock()
        if succeeded {
            NSLog("[hyperdisplay] capture frame rate -> %dfps display=%u", target, displayID)
        }
        if followUp { requestFrameRate(desired) }
    }

    private static func makeConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        cfg.queueDepth = 3
        // Cursor 单独走极轻量的坐标 UDP，并由 Android 在最上层绘制。SCK 对虚拟屏
        // 的 showsCursor 并不稳定，且与叠加层同时启用会偶发双光标。
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.capturesAudio = false
        return cfg
    }

    /// WindowServer 已经列出显示器后，ScreenCaptureKit 仍可能延后数秒才返回它。
    /// 15 秒不是体验上的阻塞（调用方异步等待），而是避免 USB/后台快速重连时把
    /// 「尚在注册的旧屏」误判成创建失败再立刻创建下一块。
    static func isDisplayVisibleToScreenCaptureKit(displayID: CGDirectDisplayID) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return false }
        return content.displays.contains(where: { $0.displayID == displayID })
    }

    private func waitForDisplay(displayID: CGDirectDisplayID) async throws -> SCShareableContent {
        for attempt in 0..<150 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if content.displays.contains(where: { $0.displayID == displayID }) {
                return content
            }
            if attempt == 0 {
                NSLog("[hyperdisplay] waiting for display %u to appear in SCShareableContent...", displayID)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HostError("virtual display \(displayID) never appeared in SCShareableContent")
    }

    // SCStreamOutput
    // macOS 26 上对静态虚拟屏：complete(1) 事件无缓冲，idle(0) 事件反而带最新缓冲。
    // 策略：有缓冲即更新 lastFrame；complete 帧直接编码；idle 帧不主动编码
    //（静态桌面不出码率，关键帧请求走 replayLastFrame）。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return }
        let statusRaw = first[SCStreamFrameInfo.status.rawValue] as? Int ?? -1
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        lock.lock()
        statusCounts[statusRaw, default: 0] += 1
        lastEventAt = Date()
        if let pixelBuffer {
            lastFrame = pixelBuffer
            buffersSeen &+= 1
        }
        if loggedEvents < 8 {
            loggedEvents += 1
            let size = pixelBuffer.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "nil"
            NSLog("[hyperdisplay] sck event status=\(statusRaw) buffer=\(size)")
        }
        lock.unlock()
        if statusRaw == SCFrameStatus.complete.rawValue, let pixelBuffer {
            lock.lock()
            capturedFrames &+= 1
            lock.unlock()
            onFrame?(pixelBuffer)
            return
        }
        // idle 通道兜底：complete 恒无 buffer 的构建上，内容更新以 idle 帧送达。
        // 新 surface 才编码——静态桌面的 idle 重复帧（macOS 周期性重发同一 buffer）不编码
        if statusRaw == SCFrameStatus.idle.rawValue, let pixelBuffer {
            let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
            let sid = surface.map { IOSurfaceGetID($0) } ?? 0
            let seed = surface.map { IOSurfaceGetSeed($0) } ?? 0
            lock.lock()
            // SCK 在 macOS 26 上可能复用同一个 IOSurface，只改变其 seed。只比
            // surface ID 会把真实桌面更新误判为静态重复帧。
            let fresh = sid != 0 && (sid != lastIdleSurfaceID || seed != lastIdleSurfaceSeed)
            lastIdleSurfaceID = sid
            lastIdleSurfaceSeed = seed
            if fresh { capturedFrames &+= 1 }
            lock.unlock()
            if fresh {
                onFrame?(pixelBuffer)
            }
        }
    }




    /// SCK 帧状态直方图（菜单栏诊断用）
    var statusSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return statusCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[hyperdisplay] capture stopped: \(error.localizedDescription)")
        onFailure?(error.localizedDescription)
    }
}
