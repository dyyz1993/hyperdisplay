import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import os.log

private let diag = Logger(subsystem: "com.hyperdisplay.session", category: "pipeline")

/// 单块虚拟屏的解码管线（对照 MainActivity.DisplayPipeline + VideoDecoder.kt 移植）：
/// - CONFIG 参数集 → CMVideoFormatDescription（VTS 需要，MediaCodec 用 csd-0 的对应物）；
/// - 完整帧先进 FIFO（容量 4），满时拒绝并要求上层等 IDR——已编码依赖帧绝不越过缺口；
/// - WELCOME 是格式边界：拓扑/分辨率切换后清空旧 CSD 等新 CONFIG，不以旧参数集抢跑。
///
/// 线程模型（2026-08-29 流畅度重构）：全部状态变更走 `stateQueue` 串行队列——
/// 分片组装/整帧拼接曾压在主线程上，是"整体卡顿不如安卓丝滑"的主因（安卓在
/// 收包线程组装、解码线程直写 Surface，主线程零参与）。解码输出在 VT 回调线程
/// 直接 enqueue（AVSampleBufferDisplayLayer.enqueue 允许任意线程），上屏节奏与
/// 主线程负载彻底解耦；仅 begin/首帧回调这类 UI 动作回主线程。
final class VideoPipeline {

    struct Callbacks {
        /// 可能在视频线程被调（已限频，频率低）：实现方自行保证线程安全
        var requestKeyframe: (UInt32) -> Void
        var sendNack: (UInt32, UInt32, [UInt16]) -> Void
        /// 首帧真正上屏（等待画面消失的信号）；保证主线程回调
        var firstFrameRendered: () -> Void
    }

    let displayId: UInt32
    private let callbacks: Callbacks

    /// 状态串行队列：分片/CONFIG/WELCOME/重置的唯一入口，替代旧的"全在 MainActor"
    private let stateQueue = DispatchQueue(label: "hyperdisplay.pipeline", qos: .userInteractive)
    private let statsLock = NSLock()
    private var widthBacking = 0
    private var heightBacking = 0
    private var renderedBacking = 0

    /// 供统计/拓扑确认读取（跨线程快照）
    var width: Int { statsLock.lock(); defer { statsLock.unlock() }; return widthBacking }
    var height: Int { statsLock.lock(); defer { statsLock.unlock() }; return heightBacking }
    var framesRendered: Int { statsLock.lock(); defer { statsLock.unlock() }; return renderedBacking }

    // 协商状态（stateQueue 读写）
    private var codec: UInt8 = 0
    private var fps = 30
    private var csd: Data?
    private var engine: DecoderEngine?
    private var surfaceViewRef: VideoLayerView?
    private var firstFrameAnnounced = false

    lazy private(set) var assembler = FrameAssembler(callbacks: .init(
        onFrame: { [weak self] frameId, keyframe, data in self?.submitToDecoder(frameId, keyframe, data) },
        onKeyframeNeeded: { [weak self] _ in
            guard let self else { return }
            self.callbacks.requestKeyframe(self.displayId)
        },
        onNackKeyframeFragments: { [weak self] frameId, missing in
            guard let self else { return }
            self.callbacks.sendNack(self.displayId, UInt32(clamping: frameId), missing)
        }
    ))

    init(displayId: UInt32, callbacks: Callbacks) {
        self.displayId = displayId
        self.callbacks = callbacks
    }

    // MARK: - 会话回调（薄封装：全部 funnel 进 stateQueue）

    func handleWelcome(codec newCodec: UInt8, width w: Int, height h: Int, fps f: Int) {
        stateQueue.async { self.handleWelcomeOnQueue(codec: newCodec, width: w, height: h, fps: f) }
    }

    func handleConfig(_ paramSets: Data) {
        stateQueue.async { self.handleConfigOnQueue(paramSets) }
    }

    func handleFragment(frameId: Int64, fragIdx: Int, fragCount: Int, keyframe: Bool, payload: Data) {
        stateQueue.async {
            self.assembler.onFragment(frameId: frameId, fragIdx: fragIdx, fragCount: fragCount,
                                      keyframe: keyframe, payload: payload)
        }
    }

    /// 停滞检测（stallTick 每 200ms 驱动）
    func heartbeat() {
        stateQueue.async { self.assembler.stallCheck() }
    }

    func resetForLinkDown() {
        stateQueue.async {
            self.releaseDecoderOnQueue()
            self.csd = nil
            self.setRendered(0)
            self.firstFrameAnnounced = false
            self.assembler.reset()
        }
    }

    func teardown() {
        stateQueue.async {
            self.releaseDecoderOnQueue()
            self.surfaceViewRef = nil
        }
    }

    /// SwiftUI 挂载/换视图时调用（主线程）；图层配置回主线程执行
    func attachSurface(_ view: VideoLayerView?) {
        stateQueue.async {
            self.surfaceViewRef = view
            self.tryStartDecoderOnQueue()
        }
    }

    // MARK: - 解码器（stateQueue 上下文）

    private func submitToDecoder(_ frameId: Int64, _ keyframe: Bool, _ data: Data) {
        guard let engine else { return } // CONFIG 未到：帧丢弃，assembler 自会请求 IDR
        if !engine.submit(keyframe: keyframe, data: data) {
            // 完整依赖帧因解码背压被拒时，后续帧不能跨过缺口。assembler 丢到下一张 IDR，
            // 同时把拥塞反馈给 Host。
            assembler.requireKeyframeAfterDecoderBackpressure(frameId: frameId)
        }
    }

    private func handleWelcomeOnQueue(codec newCodec: UInt8, width w: Int, height h: Int, fps f: Int) {
        let formatChanged = width != w || height != h || codec != newCodec
        if formatChanged {
            releaseDecoderOnQueue()
            csd = nil
            setRendered(0)
            assembler.reset()
            diag.log("vp[\(self.displayId)]: format changed -> \(w)x\(h) codec=\(newCodec)")
        }
        codec = newCodec
        statsLock.lock()
        widthBacking = w
        heightBacking = h
        statsLock.unlock()
        fps = max(1, min(f, 144))
        if formatChanged { callbacks.requestKeyframe(displayId) }
    }

    private func handleConfigOnQueue(_ paramSets: Data) {
        // csd 完整性防御：CONFIG 走不可靠通道，坏参数集会毁掉之后所有解码器重建
        guard paramSets.count >= 20,
              paramSets[paramSets.startIndex] == 0x00,
              paramSets[paramSets.startIndex + 1] == 0x00,
              paramSets[paramSets.startIndex + 2] == 0x00,
              paramSets[paramSets.startIndex + 3] == 0x01 else {
            diag.log("vp[\(self.displayId)]: drop malformed csd len=\(paramSets.count)")
            return
        }
        let old = csd
        if old != nil && engine != nil && old != paramSets {
            releaseDecoderOnQueue()
            csd = paramSets
            tryStartDecoderOnQueue()
            return
        }
        csd = paramSets
        tryStartDecoderOnQueue()
    }

    private func tryStartDecoderOnQueue() {
        guard engine == nil else { return }
        let hasSurface = surfaceViewRef != nil
        guard let csd else {
            diag.log("vp[\(self.displayId)]: decoder wait csd surface=\(hasSurface)")
            return
        }
        let w = width, h = height
        guard w > 0, h > 0, hasSurface else {
            diag.log("vp[\(self.displayId)]: decoder wait surface=\(hasSurface) w=\(w) h=\(h)")
            return
        }
        // 按 host 实际使用的编码选解码器——硬编 HEVC 会话耗尽回退 H.264 时，
        // 若仍开 HEVC 解码器会输出异常
        let kind: DecoderEngine.CodecKind = (codec == 2) ? .h264 : .hevc
        do {
            let eng = try DecoderEngine(kind: kind, fps: fps, csd: csd)
            eng.outputHandler = { [weak self, weak view = surfaceViewRef] sample in
                guard let self else { return }
                let rendered = self.incrementRendered()
                if rendered == 1 && !self.firstFrameAnnounced {
                    self.firstFrameAnnounced = true
                    diag.log("vp[\(self.displayId)]: FIRST FRAME DECODED")
                    DispatchQueue.main.async { self.callbacks.firstFrameRendered() }
                }
                // enqueue 允许任意线程（AVSampleBufferDisplayLayer 文档语义）：
                // 直接在 VT 输出回调上屏，上屏节奏与主线程负载解耦
                view?.enqueue(sample)
            }
            engine = eng
            if let view = surfaceViewRef {
                let format = eng.formatDescription
                DispatchQueue.main.async { view.begin(formatDescription: format) }
            }
            diag.log("vp[\(self.displayId)]: decoder started \(w)x\(h)")
        } catch {
            diag.log("vp[\(self.displayId)]: decoder start failed \(String(describing: error))")
        }
    }

    private func releaseDecoderOnQueue() {
        engine?.invalidate()
        engine = nil
    }

    private func incrementRendered() -> Int {
        statsLock.lock()
        renderedBacking += 1
        let value = renderedBacking
        statsLock.unlock()
        return value
    }

    private func setRendered(_ value: Int) {
        statsLock.lock()
        renderedBacking = value
        statsLock.unlock()
    }
}

// MARK: - Annex-B 工具

enum AnnexB {

    /// 扫描 Annex-B 流中的 NAL（去掉起始码与尾部对齐零）
    static func nals(in data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        // 记录每个起始码的起点与载荷起点：上一段 NAL 的右边界是下一起始码的"零前缀"开头，
        // 否则起始码字节会混进上一 NAL 尾部（单元测试抓过这个 bug）。
        var codes: [(zeroStart: Int, payloadStart: Int)] = []
        var i = 0
        while i < bytes.count - 2 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    codes.append((i, i + 3))
                    i += 3
                    continue
                }
                if i < bytes.count - 3 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    codes.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var out: [[UInt8]] = []
        out.reserveCapacity(codes.count)
        for (k, code) in codes.enumerated() {
            let end = (k + 1 < codes.count) ? codes[k + 1].zeroStart : bytes.count
            var nal = Array(bytes[code.payloadStart..<max(code.payloadStart, end)])
            while nal.last == 0x00 { nal.removeLast() } // 防尾随对齐零
            if !nal.isEmpty { out.append(nal) }
        }
        return out
    }

    /// NAL 列表 → AVCC 连续数据（每个 NAL 前 4 字节大端长度）
    static func avccData(from nals: [[UInt8]]) -> Data {
        var out = Data()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let n = UInt32(nal.count)
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            out.append(contentsOf: nal)
        }
        return out
    }

    static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription,
                                 ptsUs: Int64, durationUs: Int64) throws -> CMSampleBuffer {
        let count = avcc.count
        guard count > 0 else { throw DecoderError.sampleBuffer(-1) }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<UInt64>.alignment)
        defer { mem.deallocate() }
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: count)

        // kCMBlockBufferAssureMemoryNowFlag == 1<<0
        let assureMemoryNow: UInt32 = 1 << 0
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count,
            flags: assureMemoryNow, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            throw DecoderError.blockBuffer(status)
        }
        status = CMBlockBufferReplaceDataBytes(with: mem, blockBuffer: buffer, offsetIntoDestination: 0,
                                               dataLength: count)
        guard status == kCMBlockBufferNoErr else { throw DecoderError.blockBuffer(status) }

        let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
        let dur = CMTime(value: CMTimeValue(durationUs), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var size = count
        var sampleOut: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
                                           formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                           sampleBufferOut: &sampleOut)
        guard status == noErr, let sample = sampleOut else {
            throw DecoderError.sampleBuffer(status)
        }
        return sample
    }
}

enum DecoderError: Error {
    case parameterSets
    case formatDescription(OSStatus)
    case session(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
}

// MARK: - VTDecompressionSession 引擎

/**
 * VideoToolbox 硬解引擎，对照 android/.../VideoDecoder.kt：
 * - 输入侧保留已编码帧 FIFO；队列满时拒绝新帧并要求上层等待 IDR，绝不跨过 P 帧；
 * - 输出经 AVSampleBufferDisplayLayer 呈现（layer 内部只播最新，天然满足渲染策略）。
 */
final class DecoderEngine {

    enum CodecKind { case hevc, h264 }

    var outputHandler: ((CMSampleBuffer) -> Void)?
    let formatDescription: CMVideoFormatDescription

    private let stateLock = NSLock()
    private let workAvailable = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private var invalidated = false
    private var pendingFrames: [(key: Bool, data: Data)] = []
    var decodeSubmitted = 0
    var decodeSyncErrors = 0
    var decodeOutputs = 0
    var outputFailures = 0
    var handlerCalls = 0
    /// 像素缓冲对应的 format description（与压缩流 format desc 是两回事），按像素格式缓存
    private var imageBufferFormat: CMVideoFormatDescription?
    private var imageBufferFormatKind: OSType = 0
    private var frameDurationUs: Int64 = 16_667
    private var decompressionSession: VTDecompressionSession?

    static let maxInFlight = 4
    /// kVTDecodeFrame_EnableAsynchronousDecompression（C 常量在本 SDK 导出名不稳定，按位值引用）
    private static let flagAsyncDecode: VTDecodeFrameFlags = VTDecodeFrameFlags(rawValue: 1 << 0)

    init(kind: CodecKind, fps: Int, csd: Data) throws {
        let nals = AnnexB.nals(in: csd)
        guard !nals.isEmpty else { throw DecoderError.parameterSets }

        switch kind {
        case .hevc:
            // VPS=32 SPS=33 PPS=34（NAL 头第 6..11 位）；HEVC 创建接口要求恰好三件套按序给出
            func typeOf(_ nal: [UInt8]) -> Int { Int((nal[0] >> 1) & 0x3F) }
            let ordered = [32, 33, 34].compactMap { t in nals.first { typeOf($0) == t } }
            guard ordered.count == 3 else { throw DecoderError.parameterSets }
            formatDescription = try Self.makeFormat(ordered, hevc: true)
        case .h264:
            // SPS=7 PPS=8
            func typeOf(_ nal: [UInt8]) -> Int { Int(nal[0]) & 0x1F }
            guard let sps = nals.first(where: { typeOf($0) == 7 }),
                  let pps = nals.first(where: { typeOf($0) == 8 }) else {
                throw DecoderError.parameterSets
            }
            formatDescription = try Self.makeFormat([sps, pps], hevc: false)
        }

        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        // 头文件文档明确：EnableHardwareAcceleratedVideoDecoder 与 RealTime 均“true by
        // default”，无需显式设置（这两处常量在新 SDK 的 Swift 导入层有兼容性问题）。
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: formatDescription,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: nil,
                                                  outputCallback: &record,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let created = session else {
            throw DecoderError.session(status)
        }
        decompressionSession = created
        // 与 MediaCodec KEY_FRAME_RATE 同理：部分硬解按标称节奏调度，滚动会显得拖沓
        frameDurationUs = Int64(1_000_000 / max(1, min(fps, 144)))

        let thread = Thread { [weak self] in self?.drainLoop(session: created) }
        thread.name = "hyperdisplay-decode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        assert(decompressionSession == nil, "invalidate() must run before release")
    }

    /// 返回 false 表示 FIFO 满（调用方必须转入「等 IDR」状态）
    func submit(keyframe: Bool, data: Data) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !invalidated, pendingFrames.count < Self.maxInFlight else { return false }
        pendingFrames.append((keyframe, data))
        workAvailable.signal()
        return true
    }

    func invalidate() {
        stateLock.lock()
        let alreadyInvalidated = invalidated
        invalidated = true
        stateLock.unlock()
        if alreadyInvalidated { return }
        workAvailable.signal()
        // 等 drainLoop 退出（≤ 一个 50ms 轮询周期）再做 VT 会话清理
        _ = exited.wait(timeout: .now() + 2)
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
    }

    // MARK: 内部

    /// 独立解码线程，节奏与安卓端 VideoDecoder.loop 相同：50ms 空闲上限轮询，
    /// 静态画面不空转、有帧时立即被信号唤醒。
    private func drainLoop(session: VTDecompressionSession) {
        var ptsIndex: Int64 = 0
        while true {
            _ = workAvailable.wait(timeout: .now() + 0.05)
            stateLock.lock()
            if invalidated {
                stateLock.unlock()
                exited.signal()
                return
            }
            let frame = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
            stateLock.unlock()
            guard let frame else { continue }

            let payload = AnnexB.avccData(from: AnnexB.nals(in: frame.data))
            let ptsUs = ptsIndex * frameDurationUs
            ptsIndex += 1
            do {
                let sample = try AnnexB.makeSampleBuffer(avcc: payload, format: formatDescription,
                                                         ptsUs: ptsUs, durationUs: frameDurationUs)
                let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                           flags: Self.flagAsyncDecode,
                                                           frameRefcon: nil,
                                                           infoFlagsOut: nil)
                decodeSubmitted += 1
                if st != noErr {
                    decodeSyncErrors += 1
                    if decodeSyncErrors == 1 {
                        diag.log("DecoderEngine: DecodeFrame sync error \(st)")
                    }
                }
            } catch {
                diag.log("DecoderEngine: sample build failed \(String(describing: error))")
            }
        }
    }

    fileprivate func handleOutput(pixelBuffer: CVImageBuffer) {
        decodeOutputs += 1
        if decodeOutputs == 1 { diag.log("DecoderEngine: first output buffer") }
        // CreateReadyWithImageBuffer 拒收全 invalid 的 timing（-12743）：给真实 duration/PTS。
        // 无 B 帧，输出顺序即显示顺序，用输出计数单调推进即可。
        let timescale: CMTimeScale = 1_000_000
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameDurationUs), timescale: timescale),
            presentationTimeStamp: CMTime(value: CMTimeValue(Int64(decodeOutputs) * frameDurationUs),
                                          timescale: timescale),
            decodeTimeStamp: .invalid)
        // 这里要的是像素缓冲格式描述；传压缩流格式描述会报 -12743（required param missing）
        let kind = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if imageBufferFormat == nil || imageBufferFormatKind != kind {
            var desc: CMVideoFormatDescription?
            let st = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &desc)
            guard st == noErr, let d = desc else {
                if outputFailures == 0 {
                    diag.log("DecoderEngine: image-buffer format desc failed \(st)")
                }
                outputFailures += 1
                return
            }
            imageBufferFormat = d
            imageBufferFormatKind = kind
        }
        var sampleOut: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: imageBufferFormat!, sampleTiming: &timing, sampleBufferOut: &sampleOut)
        guard status == noErr, let sample = sampleOut else {
            if outputFailures == 0 {
                diag.log("DecoderEngine: sample-from-pixelbuffer failed status=\(status)")
            }
            outputFailures += 1
            return
        }
        guard let handler = outputHandler else {
            if outputFailures == 0 {
                diag.log("DecoderEngine: output has no handler")
            }
            outputFailures += 1
            return
        }
        handlerCalls += 1
        if handlerCalls == 1 { diag.log("DecoderEngine: invoking output handler") }
        handler(sample)
    }

    private static func makeFormat(_ nals: [[UInt8]], hevc: Bool) throws -> CMVideoFormatDescription {
        // 拷贝到连续内存；创建期间由拷贝方持有
        var copies: [UnsafeMutablePointer<UInt8>] = []
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        defer { copies.forEach { $0.deallocate() } }
        for nal in nals {
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: nal.count)
            copy.initialize(from: nal, count: nal.count)
            copies.append(copy)
            pointers.append(UnsafePointer(copy))
            sizes.append(nal.count)
        }
        var desc: CMVideoFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: nals.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: nil as CFDictionary?, formatDescriptionOut: &desc)
        } else {
            // 注意：H264 变体没有 extensions 参数（仅 HEVC 有）
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: nals.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        guard status == noErr, let d = desc else { throw DecoderError.formatDescription(status) }
        return d
    }
}

private func vtOutputCallback(_ decompressionOutputRefCon: UnsafeMutableRawPointer?,
                              _: UnsafeMutableRawPointer?, status: OSStatus,
                              infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, _: CMTime, _: CMTime) {
    guard status == noErr, let imageBuffer else {
        if status != noErr && !infoFlags.contains(.frameDropped) {
            diag.log("DecoderEngine: decode frame failed status=\(status) dropped=\(infoFlags.contains(.frameDropped))")
        }
        return
    }
    guard let pointer = decompressionOutputRefCon else { return }
    let engine = Unmanaged<DecoderEngine>.fromOpaque(pointer).takeUnretainedValue()
    engine.handleOutput(pixelBuffer: imageBuffer)
}
