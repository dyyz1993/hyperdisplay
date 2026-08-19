import Foundation
import AppKit

// MARK: - 配置

struct Config {
    var displays: [(width: Int, height: Int)] = [(1920, 1200)]
    var fps = 60
    var port: UInt16 = 5277
    /// nil = 按分辨率自动（约 5Mbps/百万像素，4–40M 区间）
    var bitrate: UInt32?
    /// 强制 H.264（诊断/兼容用）；默认 HEVC
    var forceH264 = false

    static let displayPresets: [(String, Int, Int)] = [
        ("1920×1200", 1920, 1200),
        ("2560×1600", 2560, 1600),
        ("2800×1840（平板原生）", 2800, 1840),
        ("3840×2160（4K）", 3840, 2160),
    ]

    static func autoBitrate(width: Int, height: Int) -> UInt32 {
        let megapixels = Double(width * height) / 1_000_000
        // 3.5Mbps/百万像素：office 文字够清晰，同时把大关键帧压小（WiFi 丢片率随突发size升）
        return UInt32(min(28, max(4, megapixels * 3.5))) * 1_000_000
    }

    static func parse(_ args: [String]) -> Config {
        var config = Config()
        var sawDisplay = false
        var i = 1
        func intArg() -> Int? {
            i += 1
            guard i < args.count, let v = Int(args[i]) else { return nil }
            return v
        }
        func displayArg() -> (Int, Int)? {
            i += 1
            guard i < args.count else { return nil }
            let parts = args[i].lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            return (w, h)
        }
        while i < args.count {
            switch args[i] {
            case "--display":
                if let (w, h) = displayArg() {
                    if !sawDisplay { config.displays.removeAll(); sawDisplay = true }
                    config.displays.append((min(max(640, w), 7680), min(max(480, h), 4320)))
                }
            case "--fps": if let v = intArg() { config.fps = [30, 60, 90, 144].first(where: { $0 >= v }) ?? 60 }
            case "--port": if let v = intArg() { config.port = UInt16(clamping: v) }
            case "--bitrate": if let v = intArg() { config.bitrate = UInt32(clamping: v) }
            case "--codec":
                i += 1
                if i < args.count { config.forceH264 = args[i].lowercased().contains("264") }
            default: break
            }
            i += 1
        }
        return config
    }
}

// MARK: - --check 自检（无需任何权限）：造屏 → 可见 → 销毁 → 消失

enum CheckMode {
    static func run() -> Int32 {
        print("== hyperdisplay --check ==")
        guard let vd = VirtualDisplay(width: 1920, height: 1200) else {
            print("FAIL: CGVirtualDisplay 不可用（此 macOS 版本可能移除了私有 API）")
            return 1
        }
        print("created display id=\(vd.displayID), waiting for it to become active...")
        var appeared = false
        for _ in 0..<12 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &count) == .success,
               (0..<Int(count)).contains(where: { ids[$0] == vd.displayID }) {
                appeared = true
                break
            }
            usleep(250_000)
        }
        print("active displays after create:\n\(vd.listAllDisplays())")
        guard appeared else {
            print("FAIL: virtual display never became active")
            return 1
        }
        print("OK: virtual display is active. Destroying (explicit destroy)...")
        let id = vd.displayID
        vd.destroy()
        var gone = false
        for _ in 0..<8 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &count) == .success,
               !(0..<Int(count)).contains(where: { ids[$0] == id }) {
                gone = true
                break
            }
            usleep(250_000)
        }
        print(gone ? "OK: display auto-destroyed on release." : "WARN: display still active after release (will vanish on process exit).")
        print("--check PASSED")
        return 0
    }
}

// MARK: - 客户端注册表

struct Client {
    let addr: sockaddr_in
    var displayIds: Set<CGDirectDisplayID> // 单屏=1个元素；分屏=多个
    var lastSeen: Date
}

func clientKey(_ addr: sockaddr_in) -> String {
    "\(addr.sin_addr.s_addr):\(addr.sin_port)"
}

func addressString(_ addr: sockaddr_in) -> String {
    var a = addr
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    withUnsafePointer(to: &a) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            _ = getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
    }
    return String(cString: host)
}

// MARK: - 每块虚拟屏一路独立的 采集→编码→发送 会话

final class DisplayStream {
    let display: VirtualDisplay
    let fps: Int
    let bitrate: UInt32
    private weak var host: HostApp?
    private let udp: UdpHost

    private var capture: CaptureEngine?
    private var encoder: VideoEncoder?
    let injector = InputInjector()
    private var frameId: UInt32 = 0
    private var lastKeyframeRequestAt = Date.distantPast
    private var starting = false
    private(set) var started = false
    private(set) var effectiveFps = 0
    private var encodedSnapshot: UInt64 = 0
    var idleSince: Date?          // 无订阅者起始时间（自动回收用）
    var isInitialDisplay = false  // 启动配置创建的屏不参与自动回收
    // 近期关键帧的分片缓存（NACK 重传用；增量帧可丢不缓存）
    private var keyframeFragments: [UInt32: [Data]] = [:]
    private var keyframeOrder: [UInt32] = []
    private let fragLock = NSLock()

    // MARK: 自适应画质（帧率优先：丢片时先降码率、重灾降采集分辨率；静止/恢复时回升）
    private(set) var targetBitrate: UInt32
    private(set) var currentBitrate: UInt32
    private(set) var captureScale = 1.0
    private let bitrateFloor: UInt32 = 2_000_000
    private var fragmentsSentTotal: UInt64 = 0
    private var nackFragmentsTotal: UInt64 = 0
    private var windowSentBase: UInt64 = 0
    private var windowNackBase: UInt64 = 0
    private var windowStart = Date()
    private var goodWindows = 0

    init(display: VirtualDisplay, fps: Int, bitrate: UInt32, host: HostApp, udp: UdpHost) {
        self.display = display
        self.fps = fps
        self.bitrate = bitrate
        self.targetBitrate = bitrate
        // 带宽探测从低走高：4M 起步（首帧 IDR 体积减半，弱网加入更快），
        // 连续稳定后 AIMD 逐档升回目标——帧率优先
        self.currentBitrate = min(bitrate, 4_000_000)
        self.host = host
        self.udp = udp
    }

    func startIfNeeded() {
        guard !started, !starting else { return }
        starting = true

        let capture = CaptureEngine()
        let display = self.display
        let fps = self.fps
        capture.onFrame = { [weak self] pixelBuffer in
            self?.encoder?.encode(pixelBuffer: pixelBuffer)
        }
        self.capture = capture

        let encoder = VideoEncoder(
            onConfig: { [weak self] config in
                guard let self else { return }
                let codec = self.encoder?.codec ?? .hevc
                let did = UInt16(self.display.displayID & 0xFFFF)
                for var addr in self.host?.addressesOfSubscribers(of: self.display.displayID) ?? [] {
                    self.udp.send(to: &addr, Wire.config(codec: codec.rawValue, displayId: did, frameId: self.frameId, paramSets: config))
                }
            },
            onFrame: { [weak self] keyframe, payload in
                guard let self else { return }
                self.frameId &+= 1
                let addresses = self.host?.addressesOfSubscribers(of: self.display.displayID) ?? []
                let did = UInt16(self.display.displayID & 0xFFFF)
                let frags = Wire.videoFrags(displayId: did, frameId: self.frameId, keyframe: keyframe, payload: payload)
                if keyframe {
                    fragLock.lock()
                    self.keyframeFragments[self.frameId] = frags
                    self.keyframeOrder.append(self.frameId)
                    if self.keyframeOrder.count > 8 {
                        let evict = self.keyframeOrder.removeFirst()
                        self.keyframeFragments.removeValue(forKey: evict)
                    }
                    fragLock.unlock()
                }
                fragLock.lock()
                self.fragmentsSentTotal &+= UInt64(frags.count)
                fragLock.unlock()
                // 平滑匀速发送：整帧分片摊到 ~8ms 窗口内，而不是突发猛发——
                // 突发会打满 WiFi 队列/接收缓冲造成大面积丢片（实测 13-21% 丢片的主因之一）
                let fragCount = frags.count
                let perFragDelay: useconds_t = fragCount > 1 ? useconds_t(min(8000, 8_000_000 / 600)) / useconds_t(fragCount) : 0
                for var addr in addresses {
                    for (index, frag) in frags.enumerated() {
                        self.udp.sendWithBackpressure(to: &addr, frag)
                        if index < fragCount - 1 && perFragDelay > 60 {
                            usleep(perFragDelay)
                        }
                    }
                }
            }
        )
        self.encoder = encoder
        let scale = captureScale
        let scaledW = max(640, Int(Double(display.pixelWidth) * scale))
        let scaledH = max(480, Int(Double(display.pixelHeight) * scale))
        injector.updateMapping(bounds: display.bounds, streamWidth: Double(scaledW), streamHeight: Double(scaledH))

        let bitrate = currentBitrate
        let forceH264 = host?.config.forceH264 ?? false
        Task.detached { [weak self] in
            do {
                let codec = try encoder.start(width: scaledW, height: scaledH, fps: fps, bitrate: bitrate, forceH264: forceH264)
                try await capture.start(displayID: display.displayID, width: scaledW, height: scaledH, fps: fps)
                await MainActor.run {
                    self?.started = true
                    self?.starting = false
                    self?.sendWelcome(codec: codec)
                    self?.requestKeyframeAndReplay()
                    self?.host?.rebuildMenu()
                }
            } catch {
                NSLog("[hyperdisplay] stream start failed for display \(display.displayID): \(error)")
                await MainActor.run {
                    self?.starting = false
                    self?.host?.rebuildMenu()
                }
            }
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        encoder?.stop()
        encoder = nil
        started = false
        starting = false
        encodedSnapshot = 0
        effectiveFps = 0
    }

    func sendWelcome(codec: VideoEncoder.Codec? = nil) {
        let c = codec ?? encoder?.codec ?? .hevc
        let did = UInt16(display.displayID & 0xFFFF)
        let scale = captureScale
        let w = max(640, Int(Double(display.pixelWidth) * scale))
        let h = max(480, Int(Double(display.pixelHeight) * scale))
        let data = Wire.welcome(codec: c.rawValue, displayId: did, width: w, height: h, fps: fps)
        for var addr in host?.addressesOfSubscribers(of: display.displayID) ?? [] {
            udp.send(to: &addr, data)
        }
    }

    func requestKeyframeAndReplay() {
        guard Date().timeIntervalSince(lastKeyframeRequestAt) >= 0.5 else { return }
        lastKeyframeRequestAt = Date()
        encoder?.requestKeyframe()
        capture?.replayLastFrame()
    }

    /// NACK：只重传缓存中的关键帧分片
    func handleNack(frameId: UInt32, indices: [UInt16], to addr: sockaddr_in) {
        fragLock.lock()
        let frags = keyframeFragments[frameId]
        fragLock.unlock()
        guard let frags else { return }
        var sent = 0
        for idx in indices where Int(idx) < frags.count {
            var a = addr
            udp.send(to: &a, frags[Int(idx)])
            sent += 1
            if sent % 32 == 0 { usleep(500) } // 重发也匀速，避免再次冲爆队列
        }
        fragLock.lock()
        nackFragmentsTotal &+= UInt64(sent)
        fragLock.unlock()
        if sent > 0 {
            NSLog("[hyperdisplay] NACK display=\(display.displayID) frame=\(frameId) resent=\(sent)")
        }
    }

    func sampleStats() {
        guard let encoder else { return }
        let now = encoder.snapshotEncodedFrames()
        // 流重启后新会话计数从小值开始，直接按当前计数处理，避免无符号下溢
        effectiveFps = now >= encodedSnapshot ? Int(min(now - encodedSnapshot, 100_000)) : Int(min(now, 100_000))
        encodedSnapshot = now
    }

    /// 帧率优先的自适应画质：丢片率 >2% 降码率（×0.7，地板 3M）；码率到底仍 >10% 降采集
    /// 分辨率（-15%，地板 70%）；连续 3 个窗口零丢片逐级回升。降码率立即强制 IDR 生效。
    func adaptQuality(now: Date) {
        guard started else { return }
        guard now.timeIntervalSince(windowStart) >= 2.0 else { return }
        fragLock.lock()
        let sent = fragmentsSentTotal - windowSentBase
        let lost = nackFragmentsTotal - windowNackBase
        windowSentBase = fragmentsSentTotal
        windowNackBase = nackFragmentsTotal
        fragLock.unlock()
        windowStart = now

        guard sent > 300 else { return } // 窗口内流量太小，不具备统计意义
        let lossRate = Double(lost) / Double(sent)

        if lossRate > 0.02 {
            goodWindows = 0
            if currentBitrate > bitrateFloor {
                currentBitrate = max(bitrateFloor, currentBitrate * 7 / 10)
                encoder?.applyBitrate(currentBitrate)
                NSLog("[hyperdisplay] quality: loss=\(String(format: "%.1f%%", lossRate * 100)) bitrate->\(currentBitrate/1000)kbps display=\(display.displayID)")
            }
            // 采集缩放降档已禁用：macOS 26 上对虚拟屏的缩放采集（SCK width/height < 屏幕原生）
            // 会输出全绿帧（实测）。分辨率适配改由「重建更小的虚拟屏」实现（待做），
            // 当前分辨率始终与虚拟屏 1:1。
        } else if lost == 0 {
            goodWindows += 1
            if goodWindows >= 6 { // 12 秒连续零丢片才升级，防止弱网下升降振荡
                goodWindows = 0
                if currentBitrate < targetBitrate {
                    currentBitrate = min(targetBitrate, currentBitrate * 5 / 4)
                    encoder?.applyBitrate(currentBitrate)
                    NSLog("[hyperdisplay] quality: stable, bitrate->\(currentBitrate/1000)kbps display=\(display.displayID)")
                }
            }
        } else {
            goodWindows = 0
        }
    }
}

// MARK: - HostApp（菜单栏 app + 多屏注册表 + 会话编排）

final class HostApp: NSObject, NSApplicationDelegate {
    let config: Config
    private var statusItem: NSStatusItem!

    private var udp: UdpHost?
    private var streams: [CGDirectDisplayID: DisplayStream] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var clients: [String: Client] = [:]
    private let clientsLock = NSLock()
    private var permissionsGranted = false
    private var displaySerial = 0
    private var loggedInputClients = Set<String>()
    private var didIdleReset = false
    private let bonjour = BonjourAdvertiser()
    private let qrPanel = QRPanelController()

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◧"
        rebuildMenu()

        Permissions.requestAccessibility(prompt: false)
        Permissions.requestScreenRecording()

        let permissionTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollPermissionsAndStart()
        }
        RunLoop.main.add(permissionTimer, forMode: .common)

        let statsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(statsTimer, forMode: .common)

        // 光标跟踪：把真光标位置推给订阅客户端（客户端绘制常驻本地光标——
        // 系统光标已从采集画面隐藏，没有这个反馈虚拟屏上就完全没有光标）
        let cursorTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pushCursorPosition()
        }
        RunLoop.main.add(cursorTimer, forMode: .common)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: 启动

    private func pollPermissionsAndStart() {
        if !permissionsGranted {
            let screen = Permissions.hasScreenRecording()
            let ax = Permissions.hasAccessibility()
            if !screen || !ax {
                statusItem.button?.title = screen ? "◧⚠" : "⧉⚠"
                return
            }
            permissionsGranted = true
            statusItem.button?.title = "◧"
        }
        if udp == nil {
            startPipeline()
        }
    }

    private func startPipeline() {
        do {
            let udp = try UdpHost(port: config.port)
            udp.onPacket = { [weak self] packet, from in
                self?.handlePacket(packet, from: from)
            }
            udp.start()
            self.udp = udp
            for d in config.displays {
                let id = createDisplay(width: d.width, height: d.height, name: nextDisplayName())
                if let id { streams[id]?.isInitialDisplay = true }
            }
            let hostName = Host.current().localizedName ?? "Mac"
            _ = bonjour.start(name: "Hyperdisplay (\(hostName))", port: udp.port)
            NSLog("[hyperdisplay] host listening on UDP \(udp.port); \(streams.count) virtual display(s)")
        } catch {
            NSLog("[hyperdisplay] \(error)")
            return
        }
        rebuildMenu()
    }

    private func nextDisplayName() -> String {
        displaySerial += 1
        return "Hyperdisplay \(displaySerial)"
    }

    // MARK: 显示器注册表（主线程访问）

    private func createDisplay(width: Int, height: Int, name: String) -> CGDirectDisplayID? {
        guard streams.count < 8 else {
            NSLog("[hyperdisplay] display limit (8) reached")
            return nil
        }
        guard let vd = VirtualDisplay(width: width, height: height, refreshRate: Double(config.fps)) else { return nil }
        guard let udp else { return nil }
        // 多流并发时按预算均分码率：两路 6M 在 2.4GHz 上合计超带宽必丢包；
        // 均分后合计不变，AIMD 仍可按各自实测丢片率微调
        let baseBitrate = config.bitrate ?? Config.autoBitrate(width: width, height: height)
        let perStream = max(2_500_000, baseBitrate / UInt32(max(1, streams.count + 1)))
        let stream = DisplayStream(
            display: vd, fps: config.fps,
            bitrate: perStream,
            host: self, udp: udp)
        streams[vd.displayID] = stream
        displayOrder.append(vd.displayID)
        return vd.displayID
    }

    private func destroyDisplay(id: CGDirectDisplayID) {
        guard streams[id] != nil, streams.count > 1 else { return } // 至少保留一块
        streams[id]?.stop()
        streams[id]?.display.destroy()
        streams[id] = nil
        displayOrder.removeAll { $0 == id }
        clientsLock.lock()
        for key in clients.keys {
            clients[key]?.displayIds.remove(id)
        }
        clientsLock.unlock()
    }

    // MARK: 报文处理（UDP 接收线程 → 主线程分发）

    private func handlePacket(_ packet: Packet, from addr: sockaddr_in) {
        DispatchQueue.main.async { [weak self] in
            self?.handlePacketOnMain(packet, from: addr)
        }
    }

    private func handlePacketOnMain(_ packet: Packet, from addr: sockaddr_in) {
        let key = clientKey(addr)
        clientsLock.lock()
        clients[key]?.lastSeen = Date()
        clientsLock.unlock()

        switch packet {
        case .hello(let proto, let cw, let ch):
            let existing = clients[key]?.displayIds
            let targets = (existing?.isEmpty == false) ? existing! : Set([displayOrder.first].compactMap { $0 })
            clientsLock.lock()
            clients[key] = Client(addr: addr, displayIds: targets, lastSeen: Date())
            clientsLock.unlock()
            NSLog("[hyperdisplay] HELLO proto=\(proto) client=\(cw)x\(ch) from \(addressString(addr))")
            pushDisplays()
            for id in targets { subscribe(key: key, displayId: id) }

        case .selectDisplay(let id):
            guard streams[CGDirectDisplayID(id)] != nil else { break }
            pushDisplays()
            setSubscriptions(key: key, ids: [CGDirectDisplayID(id)])

        case .subscribeDisplays(let ids):
            let valid = ids.compactMap { CGDirectDisplayID(exactly: $0) }.filter { streams[$0] != nil }
            guard !valid.isEmpty else { break }
            setSubscriptions(key: key, ids: Set(valid))

        case .createDisplay(let w, let h, let name):
            let id = createDisplay(width: Int(w), height: Int(h), name: name.isEmpty ? nextDisplayName() : name)
            pushDisplays()
            if let id {
                subscribe(key: key, displayId: id)
            }

        case .destroyDisplay(let id):
            guard streams.count > 1 else { break }
            destroyDisplay(id: CGDirectDisplayID(id))
            pushDisplays()
            clientsLock.lock()
            if clients[key]?.displayIds.isEmpty == true, let fallback = displayOrder.first {
                clients[key]?.displayIds = [fallback]
                clientsLock.unlock()
                subscribe(key: key, displayId: fallback)
            } else {
                clientsLock.unlock()
            }

        case .keyframeReq(let displayId):
            if displayId == displayIdBroadcast {
                for stream in streams.values {
                    stream.requestKeyframeAndReplay()
                }
            } else if let stream = streams[CGDirectDisplayID(displayId)] {
                stream.requestKeyframeAndReplay()
            }

        case .nack(let displayId, let frameId, let indices):
            if let stream = streams[CGDirectDisplayID(displayId)] {
                stream.handleNack(frameId: frameId, indices: indices, to: addr)
            }

        case .inputMove(let displayId, let seq, let x, let y):
            if let stream = streams[CGDirectDisplayID(displayId)] {
                if loggedInputClients.insert(key).inserted {
                    NSLog("[hyperdisplay] first input from \(addressString(addr)): move=(\(x), \(y)) display=\(displayId)")
                }
                stream.injector.move(x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .inputButton(let displayId, let seq, let button, let down, let x, let y):
            if let stream = streams[CGDirectDisplayID(displayId)] {
                stream.injector.button(button, down: down != 0, x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .inputWheel(let displayId, let seq, let dx, let dy, let x, let y):
            if let stream = streams[CGDirectDisplayID(displayId)] {
                stream.injector.wheel(dx: Double(dx), dy: Double(dy), x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .ping(let seq):
            var a = addr
            udp?.send(to: &a, Wire.pong(seq: seq))

        case .recycle:
            // 客户端要换布局：整体回收流/屏（VideoToolbox 会话经反复建销会产出
            // 华为硬解渲染为全零绿的流；切布局前归零 = 每次布局都是干净编码池）
            NSLog("[hyperdisplay] recycle requested by client — rebuilding all streams/displays")
            didIdleReset = true
            fullIdleReset()
            pushDisplays()
        }
    }

    private func subscribe(key: String, displayId: CGDirectDisplayID) {
        guard streams[displayId] != nil else { return }
        clientsLock.lock()
        clients[key]?.displayIds.insert(displayId)
        clientsLock.unlock()
        streams[displayId]?.startIfNeeded()
        streams[displayId]?.sendWelcome()
    }

    /// 单屏/分屏模式的订阅集整体切换
    private func setSubscriptions(key: String, ids: Set<CGDirectDisplayID>) {
        clientsLock.lock()
        let removed = clients[key]?.displayIds.subtracting(ids) ?? []
        clients[key]?.displayIds = ids
        clientsLock.unlock()
        for id in ids where streams[id] != nil {
            streams[id]?.startIfNeeded()
            streams[id]?.sendWelcome()
        }
        _ = removed // 移除的屏在 tick 中因无订阅者自动停流
    }

    private func pushDisplays() {
        let data = Wire.displaysList(displayListEntries())
        clientsLock.lock()
        let addresses = clients.values.map { $0.addr }
        clientsLock.unlock()
        for var addr in addresses {
            udp?.send(to: &addr, data)
        }
    }

    private func displayListEntries() -> [DisplayListEntry] {
        displayOrder.compactMap { id in
            guard let s = streams[id] else { return nil }
            return DisplayListEntry(
                id: UInt32(id),
                width: UInt16(s.display.pixelWidth),
                height: UInt16(s.display.pixelHeight),
                name: "屏 \(displayOrder.firstIndex(of: id).map { $0 + 1 } ?? 0) · \(s.display.pixelWidth)×\(s.display.pixelHeight)")
        }
    }

    func addressesOfSubscribers(of displayId: CGDirectDisplayID) -> [sockaddr_in] {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.values.filter { $0.displayIds.contains(displayId) }.map { $0.addr }
    }

    // MARK: 周期 tick：统计 + 客户端 prune

    /// 全量自愈：销毁全部流与虚拟屏，重建初始配置（编码器池归零）
    private func fullIdleReset() {
        for id in displayOrder {
            streams[id]?.stop()
            streams[id]?.display.destroy()
        }
        streams.removeAll()
        displayOrder.removeAll()
        for d in config.displays {
            let id = createDisplay(width: d.width, height: d.height, name: nextDisplayName())
            if let id { streams[id]?.isInitialDisplay = true }
        }
        NSLog("[hyperdisplay] idle reset: \(streams.count) fresh display(s), encoder pool recycled")
        rebuildMenu()
    }

    private func tick() {
        let now = Date()
        clientsLock.lock()
        let stale = clients.filter { now.timeIntervalSince($0.value.lastSeen) > 6 }.map { $0.key }
        for key in stale { clients.removeValue(forKey: key) }
        let clientCount = clients.count
        clientsLock.unlock()
        if !stale.isEmpty {
            NSLog("[hyperdisplay] pruned \(stale.count) stale client(s)")
        }
        // 空闲自愈：最后一个客户端断开后全量重建（VideoToolbox 会话经反复建销会劣化——
        // 新会话产出 ffmpeg 可解但华为硬解输出全零的流；归零重建即恢复）
        if clientCount == 0 && !didIdleReset {
            // 仅在管线就绪且有东西可回收时执行（避免启动竞态把初始屏清成 0）
            if udp != nil && !displayOrder.isEmpty {
                didIdleReset = true
                fullIdleReset()
            }
        } else if clientCount > 0 {
            didIdleReset = false
        }
        for stream in streams.values {
            stream.sampleStats()
            stream.adaptQuality(now: now)
            if addressesOfSubscribers(of: stream.display.displayID).isEmpty {
                if stream.started { stream.stop() }
                if stream.idleSince == nil { stream.idleSince = now }
            } else {
                stream.idleSince = nil
            }
        }
        // 闲置回收：协议创建的屏 60s 无人订阅且还留有其他屏 → 销毁
        // （防止客户端异常退出/反复换布局后孤儿屏堆积、占满上限）
        for id in displayOrder {
            guard let s = streams[id] else { continue }
            if !s.isInitialDisplay, let idle = s.idleSince,
               now.timeIntervalSince(idle) > 60, streams.count > 1 {
                NSLog("[hyperdisplay] recycling idle display \(id) (no subscribers 60s)")
                destroyDisplay(id: id)
            }
        }
        rebuildMenu(clientCount: clientCount)
    }

    private var lastCursorKey = ""

    private func pushCursorPosition() {
        guard let udp, let loc = CGEvent(source: nil)?.location else { return }
        // 找光标所在的虚拟屏（CG 全局坐标与 CGDisplayBounds 同一空间）
        for id in displayOrder {
            guard let s = streams[id] else { continue }
            let b = s.display.bounds
            guard loc.x >= b.minX, loc.x < b.maxX, loc.y >= b.minY, loc.y < b.maxY else { continue }
            let addresses = addressesOfSubscribers(of: id)
            guard !addresses.isEmpty else { continue }
            // CGDisplay 尺寸=显示坐标；流可能不同（保持 1:1 后相同）
            let sx = Float((loc.x - b.minX) / b.width * CGFloat(s.display.pixelWidth))
            let sy = Float((loc.y - b.minY) / b.height * CGFloat(s.display.pixelHeight))
            let key = "\(id):\(Int(sx)),\(Int(sy))"
            if key == lastCursorKey { return }
            lastCursorKey = key
            let pkt = Wire.cursor(displayId: UInt16(id & 0xFFFF), x: sx, y: sy)
            for var addr in addresses { udp.send(to: &addr, pkt) }
            return
        }
        // 光标不在任何虚拟屏上 → 通知客户端隐藏（只发一次）
        if lastCursorKey != "off" {
            lastCursorKey = "off"
            let pkt = Wire.cursor(displayId: 0, x: 0, y: 0)
            clientsLock.lock()
            let all = clients.values.map { $0.addr }
            clientsLock.unlock()
            for var addr in all { udp.send(to: &addr, pkt) }
        }
    }

    // MARK: 菜单栏

    func rebuildMenu(clientCount: Int = -1) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hyperdisplay — Mac 虚拟扩展屏", action: nil, keyEquivalent: "")

        if !Permissions.hasScreenRecording() || !Permissions.hasAccessibility() {
            menu.addItem(.separator())
            if !Permissions.hasScreenRecording() {
                menu.addItem(withTitle: "⚠ 缺少「屏幕录制」权限", action: nil, keyEquivalent: "")
            }
            if !Permissions.hasAccessibility() {
                menu.addItem(withTitle: "⚠ 缺少「辅助功能」权限", action: nil, keyEquivalent: "")
            }
            menu.addItem(withTitle: "系统设置 → 隐私与安全性 中授权后自动继续", action: nil, keyEquivalent: "")
            if !Permissions.hasScreenRecording() {
                let item = menu.addItem(withTitle: "重新触发屏幕录制授权弹窗…", action: #selector(requestScreenPerm), keyEquivalent: "")
                item.target = self
            }
        }

        menu.addItem(.separator())
        for (index, id) in displayOrder.enumerated() {
            guard let s = streams[id] else { continue }
            let subscribers = addressesOfSubscribers(of: id).count
            let scalePct = Int(s.captureScale * 100)
            let mb = s.currentBitrate / 1_000_000
            let targetMb = s.targetBitrate / 1_000_000
            let line = "屏 \(index + 1): \(s.display.pixelWidth)×\(s.display.pixelHeight)"
                + (s.started ? " · \(s.effectiveFps)fps · \(mb)/\(targetMb)M · 采集\(scalePct)% · \(subscribers)客户端" : " · 待客户端")
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
        }

        let add = menu.addItem(withTitle: "添加虚拟屏", action: nil, keyEquivalent: "")
        let addSub = NSMenu()
        for (index, preset) in Config.displayPresets.enumerated() {
            let item = NSMenuItem(title: preset.0, action: #selector(addDisplayPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            addSub.addItem(item)
        }
        menu.setSubmenu(addSub, for: add)

        let remove = menu.addItem(withTitle: "移除虚拟屏", action: nil, keyEquivalent: "")
        let removeSub = NSMenu()
        for (index, id) in displayOrder.enumerated() {
            guard streams[id] != nil else { continue }
            let item = NSMenuItem(title: "屏 \(index + 1) (\(streams[id]!.display.pixelWidth)×\(streams[id]!.display.pixelHeight))",
                                  action: #selector(removeDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            removeSub.addItem(item)
        }
        if streams.count <= 1 {
            remove.isEnabled = false
        }
        menu.setSubmenu(removeSub, for: remove)

        menu.addItem(.separator())
        let qrItem = menu.addItem(withTitle: "显示连接二维码…", action: #selector(showQR), keyEquivalent: "")
        qrItem.target = self
        let port = udp?.port ?? config.port
        menu.addItem(withTitle: "本机 UDP \(port)：", action: nil, keyEquivalent: "")
        for line in Self.allInterfaceAddresses(port: Int(port)) {
            menu.addItem(withTitle: "  \(line)", action: nil, keyEquivalent: "")
        }
        if clientCount >= 0 {
            menu.addItem(withTitle: "客户端: \(clientCount) 个在线", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出（全部虚拟屏自动销毁）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    @objc private func addDisplayPreset(_ sender: NSMenuItem) {
        guard Config.displayPresets.indices.contains(sender.tag) else { return }
        let preset = Config.displayPresets[sender.tag]
        if createDisplay(width: preset.1, height: preset.2, name: nextDisplayName()) != nil {
            pushDisplays()
        }
        rebuildMenu()
    }

    @objc private func removeDisplay(_ sender: NSMenuItem) {
        destroyDisplay(id: CGDirectDisplayID(sender.tag))
        pushDisplays()
        rebuildMenu()
    }

    @objc private func showQR() {
        let port = Int(udp?.port ?? config.port)
        let ips = Self.allInterfaceAddresses(port: port)
        let list = ips.compactMap { line -> (String, Int)? in
            // "192.168.0.9（en0）:5277" → ("192.168.0.9:5277", 5277)
            guard let ip = line.split(whereSeparator: { $0 == "（" }).first else { return nil }
            return (String(ip), port)
        }
        qrPanel.show(ipPortList: list.isEmpty ? [("?.?.?.?:\(port)", port)] : list, port: port)
    }

    @objc private func requestScreenPerm() {
        Permissions.requestScreenRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bonjour.stop()
        for stream in streams.values {
            stream.stop()
            stream.display.destroy()
        }
        streams.removeAll()
    }

    // MARK: 网卡地址（含 USB 网络共享虚拟网卡）

    static func allInterfaceAddresses(port: Int) -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ["?"] }
        defer { freeifaddrs(ifaddr) }
        var best = [String: (Int, String)]()
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let iface = p.pointee
            ptr = iface.ifa_next
            let flags = Int32(iface.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254") { continue }
            let name = String(cString: iface.ifa_name)
            // en0（主 WiFi）优先，bridge*（共享）与 en*（含 USB 网卡）其次，其余最后
            let priority: Int
            if name == "en0" { priority = 0 } else if name.hasPrefix("bridge") { priority = 1 } else if name.hasPrefix("en") { priority = 2 } else { priority = 3 }
            best[name] = (priority, address)
        }
        let out = best.sorted { $0.value.0 == $1.value.0 ? $0.key < $1.key : $0.value.0 < $1.value.0 }
            .map { "\($0.value.1)（\($0.key)）:\(port)" }
        return out.isEmpty ? ["?"] : out
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if args.contains("--check") {
    exit(CheckMode.run())
}

let config = Config.parse(args)
let app = NSApplication.shared
let delegate = HostApp(config: config)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
