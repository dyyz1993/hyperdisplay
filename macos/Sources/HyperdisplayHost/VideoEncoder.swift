import Foundation
import VideoToolbox
import CoreImage
import AppKit
import CoreMedia
import CoreVideo

/// VideoToolbox realtime 编码：HEVC 硬编优先，H.264 硬编兜底。
/// RealTime、无 B 帧；输出转 Annex-B，参数集随关键帧由 onConfig 下发。
final class VideoEncoder {
    enum Codec: UInt8 { case hevc = 1, h264 = 2 }

    /// 关键帧编码完成时回调（Annex-B 参数集），先于该帧的 onFrame
    let onConfig: (Data) -> Void
    /// 每帧编码完成（是否关键帧, Annex-B slices）
    let onFrame: (Bool, Data) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private(set) var codec: Codec = .hevc
    private var forceKeyframeFlag = true
    private var inFlight = 0
    private let maxInFlight = 3
    private var frameCounter: Int64 = 0
    private var ptsTimescale: Int32 = 60
    private var cachedConfig = Data()
    private var nalLengthSize = 4
    private(set) var encodedFrames: UInt64 = 0

    init(onConfig: @escaping (Data) -> Void, onFrame: @escaping (Bool, Data) -> Void) {
        self.onConfig = onConfig
        self.onFrame = onFrame
    }

    /// 返回实际使用的 codec；HEVC 硬编不可用（或调用方强制）时降级 H.264。
    func start(width: Int, height: Int, fps: Int, bitrate: UInt32, forceH264: Bool = false) throws -> Codec {
        stop()
        let hwSpec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        var session: VTCompressionSession?
        var codec: Codec = .hevc

        var status: OSStatus = noErr
        if forceH264 {
            codec = .h264
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: hwSpec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: VideoEncoder.outputCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
        } else {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: hwSpec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: VideoEncoder.outputCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
            if status != noErr || session == nil {
                NSLog("[hyperdisplay] HEVC hardware encoder unavailable (status=%d), falling back to H.264", status)
                codec = .h264
                status = VTCompressionSessionCreate(
                    allocator: nil, width: Int32(width), height: Int32(height),
                    codecType: kCMVideoCodecType_H264,
                    encoderSpecification: hwSpec,
                    imageBufferAttributes: nil,
                    compressedDataAllocator: nil,
                    outputCallback: VideoEncoder.outputCallback,
                    refcon: Unmanaged.passUnretained(self).toOpaque(),
                    compressionSessionOut: &session
                )
            }
        }
        guard status == noErr, let session else {
            throw HostError("VTCompressionSessionCreate failed: \(status)")
        }

        // 2026-08-30 画质调优（USB 实测文字发糊）：RealTime 模式的编码决策偏向
        // 延迟牺牲细节，文字边缘涂抹明显。改用 Quality 优先模式——远程桌面场景
        // 帧间延迟由采集/解码主导（各 ~16ms），编码端几十 ms 的决策时间换静态
        // 文字清晰度是纯赚。Quality 值 1.0 = 该码率下最高保真。
        // AllowFrameReordering 仍关（断引用帧安全策略不变）。
        let props: [NSString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            // 0.5：静态文字锐度显著优于 RealTime，但不把 IDR 推向 DataRateLimits
            // 上限（1.0 实测 IDR 中位 1.4MB=上限的 93%，是平板负载暴涨的放大器）
            kVTCompressionPropertyKey_Quality: 0.5,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: Int(bitrate),
            // DataRateLimits 的单位是字节/秒。实时 UDP 不能靠一个远超平均码率的
            // 巨型 IDR 来“补画质”：那样一旦缺片便会整屏冻结。限制为实际码率上限，
            // 让任意关键帧保持在 Wi-Fi 可一次交付的规模。
            kVTCompressionPropertyKey_DataRateLimits: [max(500_000, Int(bitrate) / 8), 1] as [NSNumber],
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // 华为 HEVC 对断引用 P 帧不会安全续播；即使反馈包丢失，也必须快速
            // 回到一张独立可解码的画面。0.5 秒把“最新帧策略”的最坏冻结上界从
            // 2 秒收紧到半秒，运动时以细节换连贯性，静止锐化仍会补高质量 IDR。
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, fps / 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0.5,
            // Main10/High Profile：10bit 色深与更强帧内预测，静态桌面文字边缘
            // 的色带/涂抹在高码率下进一步收敛（解码端 iPhone 13/华为平板均硬解支持）
            kVTCompressionPropertyKey_ProfileLevel:
                (codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel),
        ]
        var allApplied = true
        for (key, value) in props {
            if VTSessionSetProperty(session, key: key, value: value as CFTypeRef) != noErr {
                NSLog("[hyperdisplay] encoder property %@ not applied", key)
                allApplied = false
            }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            throw HostError("VTCompressionSessionPrepareToEncodeFrames failed")
        }
        lock.lock()
        self.session = session
        self.codec = codec
        self.forceKeyframeFlag = true
        self.inFlight = 0
        self.frameCounter = 0
        self.ptsTimescale = Int32(max(1, fps))
        self.cachedConfig = Data()
        self.encodedFrames = 0
        lock.unlock()
        _ = allApplied
        NSLog("[hyperdisplay] encoder started: %@ %dx%d fps=%d bitrate=%d", codec == .hevc ? "HEVC" : "H.264", width, height, fps, bitrate)
        return codec
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s { VTCompressionSessionInvalidate(s) }
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframeFlag = true
        lock.unlock()
    }

    /// 运行时调整码率（自适应画质阶梯用）：更新 AverageBitRate + DataRateLimits 并强制 IDR，
    /// 让新码率立即生效（等下一个 GOP 才生效会拖慢降档响应）。
    func applyBitrate(_ bitrate: UInt32) {
        lock.lock()
        guard let s = session else {
            lock.unlock()
            return
        }
        lock.unlock()
        let clamped = max(1_000_000, bitrate)
        // 只调平均码率 + 同步收紧 DataRateLimits（2026-08-30 双子任务审计：
        // 冻结的 1.5MB 上限 + Quality 模式让静止 IDR 暴涨到 1.4MB/1583 片，
        // 2Mbps 链路被每秒 3 个巨型突发冲垮=平板性能恶化的主因。当年绿屏是
        // 运行中同时改多项所致；这里只收紧字节上限，方向是更小更安全的帧）
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(clamped) as CFTypeRef)
        let limits = [max(500_000, Int(clamped) / 8), 1] as NSArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        requestKeyframe()
        NSLog("[hyperdisplay] bitrate -> \(clamped / 1000)kbps")
    }

    /// 诊断开关（环境变量 HD_DUMP_SOURCE=1 触发）：把第一张采集帧原样转存 PNG，
    /// 用于源头画质判责（与平板端截图对比，分离"源糊"与"链路/编码糊"）。
    static var dumpSourcePending = ProcessInfo.processInfo.environment["HD_DUMP_SOURCE"] == "1"
    private static let dumpLock = NSLock()

    func encode(pixelBuffer: CVPixelBuffer) {
        if Self.dumpSourcePending {
            Self.dumpLock.lock()
            if Self.dumpSourcePending {
                Self.dumpSourcePending = false
                Self.dumpPixelBuffer(pixelBuffer)
            }
            Self.dumpLock.unlock()
        }
        lock.lock()
        guard session != nil, inFlight < maxInFlight else {
            lock.unlock()
            return // 编码背压：丢在编码前，依赖链不受影响
        }
        let force = forceKeyframeFlag
        forceKeyframeFlag = false
        inFlight += 1
        frameCounter += 1
        let pts = frameCounter
        let timescale = ptsTimescale
        lock.unlock()

        var properties: CFDictionary?
        if force {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as NSString: kCFBooleanTrue] as CFDictionary
        }
        // 注意：输出回调收到的 refcon 是「每帧」的 sourceFrameRefcon（建会话时的 refcon 不会传给回调）
        let status = VTCompressionSessionEncodeFrame(
            session!,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: timescale),
            duration: CMTime.invalid,
            frameProperties: properties,
            sourceFrameRefcon: Unmanaged.passUnretained(self).toOpaque(),
            infoFlagsOut: nil
        )
        if status != noErr {
            lock.lock()
            inFlight = max(0, inFlight - 1)
            lock.unlock()
            requestKeyframe()
        }
    }

    /// 线程安全的编码帧计数（菜单栏统计用）
    func snapshotEncodedFrames() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return encodedFrames
    }

    // MARK: - 输出回调（VideoToolbox 线程）

    private static let outputCallback: VTCompressionOutputCallback = { _, refcon, status, _, sampleBuffer in
        guard let refcon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleOutput(status: status, sampleBuffer: sampleBuffer)
    }

    private func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
        guard status == noErr, let sampleBuffer,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let keyframe = Self.isKeyframe(sampleBuffer)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let (config, nalSize) = Self.parameterSetsAnnexB(format, codec: codec) {
                lock.lock()
                cachedConfig = config
                nalLengthSize = nalSize
                lock.unlock()
            }
        }
        lock.lock()
        let config = cachedConfig
        let lengthSize = nalLengthSize
        encodedFrames &+= 1
        lock.unlock()
        guard !config.isEmpty else {
            NSLog("[hyperdisplay] encoder output without param sets — requesting fresh keyframe")
            requestKeyframe() // 没有参数集就无法被解码，重试关键帧
            return
        }

        let dataLength = CMBlockBufferGetDataLength(dataBuffer)
        guard dataLength > 0 else { return }
        var payload = Data(count: dataLength)
        let copyStatus = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: dataLength, destination: bytes.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        guard let annexB = Self.lengthPrefixedToAnnexB(payload, lengthSize: lengthSize) else {
            NSLog("[hyperdisplay] annex-B conversion failed (len=\(dataLength) lengthSize=\(lengthSize))")
            return
        }

        if keyframe {
            NSLog("[hyperdisplay] keyframe encoded: \(annexB.count)B, param sets \(config.count)B")
            onConfig(config) // 每个关键帧都重发参数集，客户端随时可加入
        }
        onFrame(keyframe, annexB)
    }

    // MARK: - NAL 处理

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// (Annex-B 参数集, NAL 长度前缀字节数)
    static func parameterSetsAnnexB(_ format: CMFormatDescription, codec: Codec) -> (Data, Int)? {
        let startCode = Data([0, 0, 0, 1])
        if codec == .hevc {
            var sets = [Data]()
            var headerLength: Int32 = 4
            for index in 0..<3 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var unitHeaderLength = Int32(0)
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &unitHeaderLength
                )
                guard status == noErr, let pointer else { return nil }
                sets.append(Data(bytes: pointer, count: size))
                headerLength = unitHeaderLength
            }
            var out = Data()
            for s in sets { out.append(startCode); out.append(s) }
            return (out, Int(headerLength))
        }
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var unitHeaderLength = Int32(0)
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &unitHeaderLength)
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard spsStatus == noErr, ppsStatus == noErr, let spsPointer, let ppsPointer else { return nil }
        var out = Data()
        out.append(startCode); out.append(Data(bytes: spsPointer, count: spsSize))
        out.append(startCode); out.append(Data(bytes: ppsPointer, count: ppsSize))
        return (out, Int(unitHeaderLength))
    }

    /// 长度前缀 NAL 流 → Annex-B（00 00 00 01 起始码）
    static func lengthPrefixedToAnnexB(_ data: Data, lengthSize: Int) -> Data? {
        guard lengthSize == 2 || lengthSize == 4 else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: data.count + 16)
        var offset = 0
        while offset + lengthSize <= data.count {
            let length: Int
            if lengthSize == 4 {
                length = Int(data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
                })
            } else {
                length = Int(data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
                })
            }
            let start = offset + lengthSize
            guard length > 0, start + length <= data.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(data.subdata(in: start..<start + length))
            offset = start + length
        }
        return offset == data.count ? out : nil
    }
}


extension VideoEncoder {
    static func dumpPixelBuffer(_ pb: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: "/tmp/hd-source-frame.png")
        try? data.write(to: url)
        NSLog("[hyperdisplay] source frame dumped: \(cg.width)x\(cg.height) -> \(url.path)")
    }
}
