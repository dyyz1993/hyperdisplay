import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import IOSurface

/// 只采集指定 displayID 的 SCStream。虚拟屏创建后可能要等一小会儿才会出现在
/// SCShareableContent 里，start() 内部带轮询。
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private let lock = NSLock()
    private(set) var capturedFrames: UInt64 = 0
    private var lastFrame: CVPixelBuffer?
    private var statusCounts: [Int: Int] = [:]
    private var loggedEvents = 0
    private(set) var buffersSeen: UInt64 = 0
    /// 最近一次收到任意 SCK 事件（含 idle）的时间：供停流看门狗判断流是否静默
    private(set) var lastEventAt: Date?
    /// idle 帧判新：macOS 26 某些构建上内容更新只走 idle 通道（complete 恒无
    /// buffer，2026-08-21 重启后 100% 复现）。新内容 = 新 IOSurface（SCK 不会
    /// 改写已交付的 surface）；静态桌面 = 同一 surface 复用。**不可用
    /// LockBaseAddress 采样像素**——对 SCK 的 IOSurface buffer 会死锁事件线程
    /// （实测每个实例在首个 idle 帧后冻结）。
    private var lastIdleSurfaceID: UInt32 = 0

    /// 把最近一帧重新送编码（配合 force keyframe），用于客户端中途加入/重连时
    /// 静态桌面不出新帧的场景——否则 PLI 永远等不到新源帧。
    func replayLastFrame() {
        lock.lock()
        let frame = lastFrame
        lock.unlock()
        if let frame {
            NSLog("[hyperdisplay] replaying last captured frame for forced keyframe")
            onFrame?(frame)
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
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        cfg.queueDepth = 3
        // 系统光标不进画面：光标反馈由客户端本地绘制（零延迟），
        // 否则光标要经 采集→编码→传输→解码 一整圈（50-80ms），手感明显拖沓
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()
        lock.lock()
        self.stream = stream
        lastEventAt = Date() // 起始锚点：刚启动时 idle 事件可能要几十 ms 才到
        lock.unlock()
        NSLog("[hyperdisplay] capture started for display %u (%dx%d@%d)", displayID, width, height, fps)
    }

    /// 同一流对象重启（stopCapture→startCapture）。
    /// 本 macOS 构建的 SCK 守护进程：进程内第一条 SCStream 之后新建的流全部
    /// 静默（对象正确释放也一样，2026-08-21 受控实验）。因此流一旦创建必须
    /// 永生复用——看门狗/重连一律走 restart，绝不 new CaptureEngine。
    func restart() async throws {
        lock.lock()
        let s = stream
        lastEventAt = Date()
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
        lastFrame = nil // 释放持有的 IOSurface（属于旧流，跨流持有会卡 SCK 表面池）
        lock.unlock()
        guard let s else { return }
        s.stopCapture()
        // 必须显式摘除输出：SCStream 强持有 output 回调，不摘则旧流对象永不释放
        // （ARC 无 GC），进程内出现"僵尸流"后 SCK 的新流全部静默——每进程只有
        // 第一条流能投递的根因（2026-08-21 受控实验定位）
        try? s.removeStreamOutput(self, type: .screen)
    }

    private func waitForDisplay(displayID: CGDirectDisplayID) async throws -> SCShareableContent {
        for attempt in 0..<20 {
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
            lock.lock()
            let fresh = sid != lastIdleSurfaceID && sid != 0
            lastIdleSurfaceID = sid
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
