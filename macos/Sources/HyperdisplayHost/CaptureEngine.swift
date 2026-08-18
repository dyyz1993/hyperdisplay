import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia

/// 只采集指定 displayID 的 SCStream。虚拟屏创建后可能要等一小会儿才会出现在
/// SCShareableContent 里，start() 内部带轮询。
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private let lock = NSLock()
    private(set) var capturedFrames: UInt64 = 0

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
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()
        lock.lock()
        self.stream = stream
        lock.unlock()
        NSLog("[hyperdisplay] capture started for display %u (%dx%d@%d)", displayID, width, height, fps)
    }

    func stop() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        s?.stopCapture()
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
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw HostError("virtual display \(displayID) never appeared in SCShareableContent")
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first,
              let statusRaw = first[SCStreamFrameInfo.status.rawValue] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        capturedFrames &+= 1
        lock.unlock()
        onFrame?(pixelBuffer)
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[hyperdisplay] capture stopped: \(error.localizedDescription)")
        onFailure?(error.localizedDescription)
    }
}
