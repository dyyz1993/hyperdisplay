import Foundation
import AppKit
import ServiceManagement
import HyperdisplayObjC

// MARK: - 配置

struct Config {
    /// 默认空：没人连接时一块屏都不留（HELLO 按需建屏）。显式 --display 仍可预建。
    /// 此前默认 [(1920,1200)] + 初始屏不回收 = 空闲时 WindowServer 白挂 18MB 像素缓冲。
    var displays: [(width: Int, height: Int)] = []
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
    return "\(String(cString: host)):\(CFSwapInt16BigToHost(addr.sin_port))"
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
    private var captureStartedAt: Date?
    private var lastCaptureRestartAt = Date.distantPast
    private(set) var effectiveFps = 0
    private var encodedSnapshot: UInt64 = 0
    var idleSince: Date?          // 无订阅者起始时间（自动回收用）
    var isInitialDisplay = false  // 启动配置创建的屏不参与自动回收
    // 近期关键帧的分片缓存（NACK 重传用；增量帧可丢不缓存）
    private var keyframeFragments: [UInt32: [Data]] = [:]
    private var keyframeOrder: [UInt32] = []
    private let fragLock = NSLock()
    /// 最近的 CONFIG 报文（编码参数集）：encoder 启动时只广播一次，之后接入的
    /// 订阅者必须补发——没有参数集解码器无法初始化，完整 IDR 也会被客户端丢弃
    /// （2026-08-21 端到端定位：IDR 258/258 片组装成功仍黑屏的根因）
    private var lastConfigPacket: Data?

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

    private func wireCapture(_ capture: CaptureEngine) {
        capture.onFrame = { [weak self] pixelBuffer in
            // 订阅门控：无人看时不编码（永生流方案下流不停，靠这里省编码开销）
            guard let self,
                  !(self.host?.addressesOfSubscribers(of: self.display.displayID).isEmpty ?? true)
            else { return }
            self.encoder?.encode(pixelBuffer: pixelBuffer)
        }
    }

    /// SCK 停流看门狗：macOS 26 虚拟屏上 SCStream 会偶发永久静默（连 idle 事件都停发，
    /// 实测会话开始 30s 内即可发生），客户端将冻在最后一帧且永不自愈。
    /// 有订阅者但 2.5s 零事件 → 只重建采集流（编码器会话不动——重开 VideoToolbox
    /// 会触发华为硬解绿屏），重启后等 idle 帧填充缓存再补关键帧（客户端仍显示
    /// 旧帧，无黑闪）。
    /// 升级路径（2026-08-20 实测）：中毒系统（如 ColorSync 异常）下同一块屏重启
    /// 采集流救不活，但换一块新屏立刻复活 → 90s 窗口内 3 次流重启即 fullIdleReset
    /// （重建全部屏），10 分钟限频，防 churn。注意不能用"有帧到达"清零——每次
    /// 重启后 SCK 常回光返照吐一两帧又死，帧计数永远到不了阈值。
    private var captureRestartTimes: [Date] = []
    private var lastIdleResetEscalationAt: Date?

    func restartCaptureIfNeeded(now: Date) {
        guard started, !starting, let oldCapture = capture else { return }
        guard host?.addressesOfSubscribers(of: display.displayID).isEmpty == false else { return }
        // lastEventAt == nil：流起手就没吐过任何事件（SCK 起手即死），拿启动时刻当
        // 静默参照——否则看门狗对这种流永远失明
        let neverDelivered = oldCapture.lastEventAt == nil
        guard let reference = oldCapture.lastEventAt ?? captureStartedAt else { return }
        let silent = now.timeIntervalSince(reference)
        guard silent > (neverDelivered ? 10 : 2.5), now.timeIntervalSince(lastCaptureRestartAt) > 5 else { return }
        captureRestartTimes.append(now)
        captureRestartTimes.removeAll { now.timeIntervalSince($0) > 90 }
        if captureRestartTimes.count >= 3 {
            // 一屏一流永生：不再升级 fullIdleReset（销毁永生屏 = 之后新流必死）。
            // 只记录，交给同流 restart 继续尝试。
            NSLog("[hyperdisplay] capture stuck through \(captureRestartTimes.count) restarts on display \(display.displayID) (immortal-stream mode: no escalation)")
            captureRestartTimes.removeLast()
        }
        lastCaptureRestartAt = now
        NSLog("[hyperdisplay] capture watchdog: display \(display.displayID) silent \(Int(silent))s — restarting capture")
        // 单流永生：同一条 SCStream 重启。新建流在本构建上必死（每进程仅首条可投递）
        let capture = oldCapture
        Task.detached { [weak self] in
            do {
                try await capture.restart()
                try await Task.sleep(nanoseconds: 300_000_000) // 等 idle 事件填充 lastFrame
                await MainActor.run {
                    self?.captureStartedAt = Date()
                    self?.requestKeyframeAndReplay()
                }
            } catch {
                NSLog("[hyperdisplay] capture restart failed for display \(self?.display.displayID ?? 0): \(error)")
            }
        }
    }

    func startIfNeeded() {
        guard !started, !starting else { return }
        starting = true

        let capture = CaptureEngine()
        wireCapture(capture)
        self.capture = capture
        let display = self.display
        let fps = self.fps

        let encoder = VideoEncoder(
            onConfig: { [weak self] config in
                guard let self else { return }
                let codec = self.encoder?.codec ?? .hevc
                let did = UInt16(self.display.displayID & 0xFFFF)
                let pkt = Wire.config(codec: codec.rawValue, displayId: did, frameId: self.frameId, paramSets: config)
                fragLock.lock()
                self.lastConfigPacket = pkt
                fragLock.unlock()
                for var addr in self.host?.addressesOfSubscribers(of: self.display.displayID) ?? [] {
                    self.udp.send(to: &addr, pkt)
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
                    self?.captureStartedAt = Date()
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

    /// 补发缓存的 CONFIG 给指定客户端（新订阅者错过 encoder 启动广播）。
    /// 没有参数集解码器无法初始化——完整 IDR 也会被客户端丢弃（黑屏根因）。
    func sendConfigReplay(to addr: inout sockaddr_in) {
        fragLock.lock()
        let pkt = lastConfigPacket
        fragLock.unlock()
        if let pkt { udp.send(to: &addr, pkt) }
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
    /// streams/displayOrder 只在主线程写；锁仅为 UDP 接收线程的高频包路径提供
    /// 一致性快照读（ping/nack/input 在接收线程直接处理，避免逐包 async 主线程
    /// ——那会在包洪峰下把 RunLoop Timer 全部饿死：tick/哨兵停摆、进程"假死"，
    /// 2026-08-20 实测定位。写点仍全部主线程，读用快照，无嵌套锁风险。）
    private var streams: [CGDirectDisplayID: DisplayStream] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private let streamsLock = NSLock()

    private func snapshotStreams() -> [CGDirectDisplayID: DisplayStream] {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return streams
    }
    private var clients: [String: Client] = [:]
    private let clientsLock = NSLock()
    private var permissionsGranted = false
    private var currentDeviceId: UInt32 = 0
    private var displaySerial = 0
    /// 首次输入日志（接收线程写）：SET 锁不便宜但每客户端只写一次，可接受
    private var loggedInputClientsLock = NSLock()
    private var loggedInputClients = Set<String>()
    private var didIdleReset = false
    /// 设备档案：deviceId → (宽, 高, 名称, 上次位置)。重连时按档案复建同一块屏
    /// （同分辨率同名），macOS 会把窗口按原摆放恢复——「这台设备就是这块显示器」。
    private var deviceProfiles: [UInt32: (w: Int, h: Int, name: String)] = [:]
    /// 上次建屏失败时刻：1s 退避，防客户端（弱网重连风暴）把主线程打成重试死循环
    private var lastCreateFailAt: Date?
    private var lastDeviceDisplays: [UInt32: (w: Int, h: Int)] = [:]
    /// 配对码：阻止局域网内任意设备连接（不校验则任何人都可看屏+控鼠标）
    let pairingCode: UInt32 = {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: "hyperdisplay.pairingCode") as? UInt32 {
            return saved
        }
        let generated = UInt32.random(in: 100_000...999_999)
        defaults.set(generated, forKey: "hyperdisplay.pairingCode")
        return generated
    }()
    private let bonjour = BonjourAdvertiser()
    private let qrPanel = QRPanelController()
    private let usbTunnel = UsbTunnelController()
    private let displayHealth = DisplayHealthMonitor()

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
            _ = bonjour.start(name: "Hyperdisplay (\(hostName))", port: udp.port,
                              txt: ["code": String(pairingCode)])
            // USB 隧道桥 + adb reverse 轮询（零点击：插线即用，AGENTS.md §7.1）
            usbTunnel.onDeviceCountChange = { [weak self] in self?.rebuildMenu() }
            usbTunnel.start(udpPort: udp.port)
            // 显示器卫生哨兵（AGENTS §4.1 运行时版）：ColorSync 中毒 / 孤儿屏 / churn 预算
            displayHealth.expectedDisplayIds = { [weak self] in
                guard let self else { return [] }
                return Set(self.streams.keys)
            }
            displayHealth.onOrphanDisplays = { ids in
                for id in ids { hyperdisplayDestroyVirtualDisplay(id) }
            }
            displayHealth.onAlert = { [weak self] msg in
                NSLog("[hyperdisplay] ⚠️ %@", msg)
                self?.refreshStatusIcon()
                self?.rebuildMenu()
            }
            displayHealth.start()
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
        // 失败退避：上次失败 1s 内直接放弃（曾因手机弱网重连风暴以 3ms 间隔刷爆主线程）
        if let last = lastCreateFailAt, Date().timeIntervalSince(last) < 1.0 { return nil }
        // CGVirtualDisplay 会拒绝非 16 对齐尺寸（手机原生 2131x1080 → id=0），
        // 统一对齐后再建；档案匹配/记录均用对齐值，保证重连恒定命中
        let w0 = max(640, (width + 15) & ~15)
        let h0 = max(480, (height + 15) & ~15)
        // 清晰度档位：物理长边 >2240（高密度面板原生）时等比降到 2240。
        // 已实测 CGVirtualDisplay 无法生成 HiDPI 2x 模式（密度申报到 237DPI 也只有
        // 1x 档，settings.hiDPI 同样无效）——2x 渲染不可达，清晰度只能靠像素档权衡：
        // 2800 原生(文字 ~69% 常规大小) / 2240 高清(~86%，像素量 64% 原生) / 1920 标准。
        // 默认 2240：文字明显更锐、大小仍舒适。
        let w: Int, h: Int
        if max(w0, h0) > 2240 {
            let scale = 2240.0 / Double(max(w0, h0))
            w = max(640, (Int(Double(w0) * scale) + 15) & ~15)
            h = max(480, (Int(Double(h0) * scale) + 15) & ~15)
        } else {
            w = w0; h = h0
        }
        // EDID serial：默认屏恒 1；设备档案屏 = 1000 + 设备指纹低 16 位（同一设备重连恒定）
        // → macOS 视作「同一台显示器回来了」：排列位置与窗口归属自动还原
        let serial: UInt32 = (name.hasPrefix("Hyperdisplay 设备") && currentDeviceId != 0)
            ? 1000 + UInt32(currentDeviceId % 65536) : 1
        guard let vd = VirtualDisplay(width: w, height: h, refreshRate: Double(config.fps), serial: serial) else {
            lastCreateFailAt = Date()
            return nil
        }
        displayHealth.recordCreation() // churn 预算统计（AGENTS 4.1.2 运行时版）
        guard let udp else { return nil }
        // 多流并发时按预算均分码率：两路 6M 在 2.4GHz 上合计超带宽必丢包；
        // 均分后合计不变，AIMD 仍可按各自实测丢片率微调
        let baseBitrate = config.bitrate ?? Config.autoBitrate(width: width, height: height)
        let perStream = max(2_500_000, baseBitrate / UInt32(max(1, streams.count + 1)))
        let stream = DisplayStream(
            display: vd, fps: config.fps,
            bitrate: perStream,
            host: self, udp: udp)
        streamsLock.lock()
        streams[vd.displayID] = stream
        streamsLock.unlock()
        displayOrder.append(vd.displayID) // DISPLAYS 列表源；丢失 = 客户端收不到屏列表 = 黑屏（2026-08-21 定位回归）
        if currentDeviceId != 0 {
            deviceProfiles[currentDeviceId] = (w, h, name) // 记对齐值，与屏实际尺寸/匹配口径一致
        }
        return vd.displayID
    }

    /// allowLast=true：闲置回收允许清到零屏（菜单手动移除仍保留最后一块护栏）
    private func destroyDisplay(id: CGDirectDisplayID, allowLast: Bool = false) {
        guard streams[id] != nil, allowLast || streams.count > 1 else { return }
        streams[id]?.stop()
        streams[id]?.display.destroy()
        streamsLock.lock()
        streams[id] = nil
        streamsLock.unlock()
        displayOrder.removeAll { $0 == id }
        clientsLock.lock()
        for key in clients.keys {
            clients[key]?.displayIds.remove(id)
        }
        clientsLock.unlock()
    }

    // MARK: 报文处理（UDP 接收线程 → 主线程分发）

    private func handlePacket(_ packet: Packet, from addr: sockaddr_in) {
        // 临时诊断：非 PING 报文记录（定位客户端路径致 SCK 静默的毒报文）
        if case .ping = packet {} else {
            NSLog("[hyperdisplay] pkt \(packet) from \(addressString(addr))")
        }
        // 高频包（ping/nack/input/keyframeReq/bye 轻路径）在接收线程直接处理：
        // 逐包 async 主线程会在包洪峰（多客户端×心跳×输入×NACK）下把主 RunLoop 的
        // Timer 全部饿死——tick/哨兵/看门狗停摆、进程"假死"（2026-08-20 实测定位）。
        // 这些 handler 只碰锁保护的 clients / streams 快照 / injector / udp 发送，
        // 天然线程安全；会话变更类（HELLO/SELECT/SUBSCRIBE/RECYCLE/CREATE/DESTROY）
        // 仍走主线程 async（低频、且要碰 CG/菜单）。
        switch packet {
        case .ping(let seq):
            let key = clientKey(addr)
            clientsLock.lock()
            clients[key]?.lastSeen = Date()
            let known = clients[key]?.displayIds.isEmpty == false
            clientsLock.unlock()
            var a = addr
            udp?.send(to: &a, Wire.pong(seq: seq, known: known))
        case .nack(let displayId, let frameId, let indices):
            if let stream = snapshotStreams()[CGDirectDisplayID(displayId)] {
                stream.handleNack(frameId: frameId, indices: indices, to: addr)
            }
        case .inputMove(let displayId, let seq, let x, let y):
            if let stream = snapshotStreams()[CGDirectDisplayID(displayId)] {
                loggedInputClientsLock.lock()
                let first = loggedInputClients.insert(clientKey(addr)).inserted
                loggedInputClientsLock.unlock()
                if first {
                    NSLog("[hyperdisplay] first input from \(addressString(addr)): move=(\(x), \(y)) display=\(displayId)")
                }
                stream.injector.move(x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }
        case .inputButton(let displayId, let seq, let button, let down, let x, let y):
            if let stream = snapshotStreams()[CGDirectDisplayID(displayId)] {
                stream.injector.button(button, down: down != 0, x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }
        case .inputWheel(let displayId, let seq, let dx, let dy, let x, let y):
            if let stream = snapshotStreams()[CGDirectDisplayID(displayId)] {
                stream.injector.wheel(dx: Double(dx), dy: Double(dy), x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }
        case .keyframeReq(let displayId):
            let snapshot = snapshotStreams()
            if displayId == displayIdBroadcast {
                for stream in snapshot.values {
                    stream.requestKeyframeAndReplay()
                }
            } else if let stream = snapshot[CGDirectDisplayID(displayId)] {
                stream.requestKeyframeAndReplay()
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.handlePacketOnMain(packet, from: addr)
            }
        }
    }

    private func handlePacketOnMain(_ packet: Packet, from addr: sockaddr_in) {
        let key = clientKey(addr)
        clientsLock.lock()
        clients[key]?.lastSeen = Date()
        clientsLock.unlock()

        switch packet {
        case .hello(let proto, let cw, let ch, let code, let deviceId):
            guard code == pairingCode else {
                NSLog("[hyperdisplay] HELLO from \(addressString(addr)) REJECTED (bad pairing code)")
                return
            }
            if proto == 0xFF {
                // 探针 HELLO（UsbProbe 链路检测）：只回声不注册——注册会订阅屏，
                // 周期性充电探测会把闲置回收卡死（显示永远"有人订着"）
                var a = addr
                udp?.send(to: &a, Wire.pong(seq: 0, known: false))
                return
            }
            currentDeviceId = deviceId
            // 设备档案：优先复用既有同尺寸屏（连续性），否则建一块并记住
            if deviceId != 0 {
                if let profile = deviceProfiles[deviceId] {
                    if let existing = streams.first(where: { $0.value.display.pixelWidth == profile.w && $0.value.display.pixelHeight == profile.h })?.key {
                        NSLog("[hyperdisplay] device \(deviceId) reconnected → reusing display \(existing) (\(profile.w)x\(profile.h))")
                    } else if let id = createDisplay(width: profile.w, height: profile.h, name: profile.name) {
                        NSLog("[hyperdisplay] device \(deviceId) reconnected → recreated \(profile.name) \(profile.w)x\(profile.h) id=\(id)")
                    }
                } else {
                    // 新档案存 16 对齐的原生尺寸（与建屏口径一致，重连匹配恒命中）。
                    // 舒适度不靠降分辨率（那会牺牲清晰度），改由 createDisplay 的 HiDPI
                    // 2x 渲染实现：UI 常规大小 + 原生像素锐度。
                    let aw = max(640, (Int(cw) + 15) & ~15)
                    let ah = max(480, (Int(ch) + 15) & ~15)
                    deviceProfiles[deviceId] = (aw, ah, "Hyperdisplay 设备 \(deviceId % 10000)")
                }
            }
            // 目标屏：档案屏优先（剪枝后重入会也能回到自己的屏——setSubscriptions 对
            // 不存在的客户端是空操作，不能依赖它），其次既有订阅，最后默认屏
            var targets: Set<CGDirectDisplayID> = []
            if deviceId != 0, let profile = deviceProfiles[deviceId],
               let t = streams.first(where: { $0.value.display.pixelWidth == profile.w && $0.value.display.pixelHeight == profile.h })?.key {
                targets = [t]
            } else if let e = clients[key]?.displayIds, !e.isEmpty {
                targets = e
            } else if let first = displayOrder.first {
                targets = [first]
            }
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

        case .keyframeReq, .nack, .inputMove, .inputButton, .inputWheel, .ping:
            break // 已在接收线程直接处理（见 handlePacket），主线程不再走

        case .recycle:
            // 客户端要换布局：整体回收流/屏（VideoToolbox 会话经反复建销会产出
            // 华为硬解渲染为全零绿的流；切布局前归零 = 每次布局都是干净编码池）
            NSLog("[hyperdisplay] recycle requested by client — rebuilding all streams/displays")
            didIdleReset = true
            fullIdleReset()
            pushDisplays()

        case .bye:
            // 客户端主动退场（用户关 app / 切走超过宽限）：立刻摘除订阅，并把只剩
            // 无人订阅的屏的闲置时钟回拨 10s——15s 阈值下 5s 后即回收，副屏退场、
            // 窗口弹回主屏（用户在 Mac 上看得到）；5s 宽限兜住 USB↔WiFi 换通道的
            // 先断后连。强杀/滑掉不发 BYE 的路径由 prune(6s)+GC(15s) 兜底。
            NSLog("[hyperdisplay] client \(addressString(addr)) said bye")
            clientsLock.lock()
            clients.removeValue(forKey: key)
            clientsLock.unlock()
            let backdated = nowBackdated(seconds: 10)
            for id in displayOrder {
                guard let s = streams[id] else { continue }
                if addressesOfSubscribers(of: id).isEmpty && streams.count > 1 {
                    s.idleSince = backdated
                }
            }
            pushDisplays()
        }
    }

    private func subscribe(key: String, displayId: CGDirectDisplayID) {
        guard streams[displayId] != nil else { return }
        clientsLock.lock()
        clients[key]?.displayIds.insert(displayId)
        let addr = clients[key]?.addr
        clientsLock.unlock()
        streams[displayId]?.startIfNeeded()
        streams[displayId]?.sendWelcome()
        // 参数集补发：晚加入的订阅者没有它，解码器永远起不来（黑屏根因）
        if var a = addr { streams[displayId]?.sendConfigReplay(to: &a) }
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
        let entries = displayOrder.compactMap { (id: CGDirectDisplayID) -> DisplayListEntry? in
            guard let s = streams[id] else { return nil }
            return DisplayListEntry(
                id: UInt32(id),
                width: UInt16(s.display.pixelWidth),
                height: UInt16(s.display.pixelHeight),
                name: "屏 \(displayOrder.firstIndex(of: id).map { $0 + 1 } ?? 0) · \(s.display.pixelWidth)×\(s.display.pixelHeight)")
        }
        return entries
    }

    func addressesOfSubscribers(of displayId: CGDirectDisplayID) -> [sockaddr_in] {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.values.filter { $0.displayIds.contains(displayId) }.map { $0.addr }
    }

    // MARK: 周期 tick：统计 + 客户端 prune

    /// 全量自愈：销毁全部流与虚拟屏，重建初始配置（编码器池归零）
    /// 看门狗升级入口：采集流连续重启无效（中毒系统），全量重建屏+编码器池。
    /// AGENTS 4.1.5：fullIdleReset 仅用于污染恢复——此处正是。客户端靠重 HELLO 自愈回订阅。
    func escalateToIdleReset() {
        guard !streams.isEmpty else { return }
        fullIdleReset()
    }

    private func fullIdleReset() {
        for id in displayOrder {
            streams[id]?.stop()
            streams[id]?.display.destroy()
        }
        streamsLock.lock()
        streams.removeAll()
        streamsLock.unlock()
        displayOrder.removeAll()
        for d in config.displays {
            let id = createDisplay(width: d.width, height: d.height, name: nextDisplayName())
            if let id { streams[id]?.isInitialDisplay = true }
        }
        NSLog("[hyperdisplay] idle reset: \(streams.count) fresh display(s), encoder pool recycled")
        pushDisplays() // 必须广播新列表：客户端对账靠 DISPLAYS 触发，不推就冻死在死 id 上
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
        // 一屏一流永生（2026-08-21 定稿）：本 macOS 构建的 SCK 每进程仅第一条
        // SCStream 可投递（受控实验：对象释放/旧屏销毁后新流仍全静默）。因此：
        // - 断开不回收屏、不停流——只靠"无订阅者→无编码"自然闲置（静态桌面零帧）
        // - 重连复用同屏同流（watchdog 走同流 restart）
        // - fullIdleReset 禁用（会销毁永生屏 → 之后新流必死）
        // 代价：空闲时 WindowServer 挂一块屏（~18-26MB）。Apple 修复 SCK 后
        // 恢复惰性建屏/闲置回收语义。
        if clientCount == 0 && !didIdleReset {
            didIdleReset = true // 什么都不做：保留永生屏
        } else if clientCount > 0 {
            didIdleReset = false
        }
        for stream in streams.values {
            stream.sampleStats()
            stream.adaptQuality(now: now)
            if addressesOfSubscribers(of: stream.display.displayID).isEmpty {
                // 无人订阅：编码输入自然归零（订阅门控见 wireCapture），不 stop
                if stream.idleSince == nil { stream.idleSince = now }
            } else {
                stream.idleSince = nil
                stream.restartCaptureIfNeeded(now: now)
            }
        }
        rebuildMenu(clientCount: clientCount)
    }

    private func nowBackdated(seconds: TimeInterval) -> Date {
        Date().addingTimeInterval(-seconds)
    }

    private var lastCursorKey = ""

    private var cursorTick = 0
    private func pushCursorPosition() {
        // 闲时零成本（AGENTS §7）：零客户端直接返回——20Hz 定时器照跑，但每次
        // 只是一次空 guard（不查 CGEvent 不遍历屏），不阻碍 CPU 休眠
        clientsLock.lock()
        let noClients = clients.isEmpty
        clientsLock.unlock()
        if noClients { return }
        cursorTick += 1
        if cursorTick % 100 == 1 { NSLog("[hyperdisplay] cursor tick loc=\(CGEvent(source: nil)?.location ?? .zero)") }
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
        let loginItem = menu.addItem(withTitle: loginItemTitle(), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(withTitle: "配对码: \(pairingCode)（客户端首次连接需输入）", action: nil, keyEquivalent: "")
        let qrItem = menu.addItem(withTitle: "显示连接二维码…", action: #selector(showQR), keyEquivalent: "")
        qrItem.target = self
        let port = udp?.port ?? config.port
        menu.addItem(withTitle: "本机 UDP \(port)：", action: nil, keyEquivalent: "")
        for line in Self.allInterfaceAddresses(port: Int(port)) {
            menu.addItem(withTitle: "  \(line)", action: nil, keyEquivalent: "")
        }
        if usbTunnel.adbAvailable {
            menu.addItem(withTitle: "USB 隧道 :\(UsbTunnelController.tcpPort)（\(usbTunnel.deviceCount) 台设备已配 reverse）", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "USB 隧道不可用（未找到 adb）", action: nil, keyEquivalent: "")
        }
        // 显示器卫生状态行（DisplayHealth 哨兵，三级）
        if let cpu = displayHealth.lastColorSyncCPU {
            let mark: String
            switch displayHealth.level {
            case .hot: mark = "⚠️ 中毒——请注销会话（AGENTS 4.1.6）"
            case .warm: mark = "🔶 温和残留——建议今日收工时注销一次"
            case .normal: mark = "正常"
            }
            menu.addItem(withTitle: "ColorSync \(String(format: "%.0f", cpu))%：\(mark)", action: nil, keyEquivalent: "")
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
        qrPanel.show(ipPortList: list.isEmpty ? [("?.?.?.?:\(port)", port)] : list, port: port, code: pairingCode)
    }

    @objc private func requestScreenPerm() {
        Permissions.requestScreenRecording()
    }

    // MARK: 登录自启（零点击链路：Mac 侧常驻，AGENTS.md §7.1）

    private func refreshStatusIcon() {
        switch displayHealth.level {
        case .hot: statusItem.button?.title = "◧⚠"
        case .warm: statusItem.button?.title = "◧🔶"
        case .normal: statusItem.button?.title = "◧"
        }
    }

    private func loginItemTitle() -> String {
        let on = SMAppService.mainApp.status == .enabled
        return on ? "✓ 开机自动启动" : "开机自动启动"
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // ad-hoc 签名/非 /Applications 路径下 register 可能被系统拒绝：如实记录
            NSLog("[hyperdisplay] login item toggle failed: \(error)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bonjour.stop()
        usbTunnel.stop()
        for stream in streams.values {
            stream.stop()
            stream.display.destroy()
        }
        streamsLock.lock()
        streams.removeAll()
        streamsLock.unlock()
        // 兜底：streams 之外若有漏网的显示器对象（理论上没有），一并清掉
        hyperdisplayDestroyAllVirtualDisplays()
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

// 退出卫生（AGENTS.md 4.1-3）：SIGTERM/SIGINT（pkill/Ctrl-C）不走 NSApplication
// 终止链，此前完全依赖 windowserver 进程死亡兜底——显示器 churn 的坏习惯来源。
// 信号处理里直接调 shim 的全局清理（C 函数、内部 @synchronized 线程安全）。
signal(SIGTERM) { _ in
    hyperdisplayDestroyAllVirtualDisplays()
    exit(0)
}
signal(SIGINT) { _ in
    hyperdisplayDestroyAllVirtualDisplays()
    exit(0)
}
// SIGPIPE 忽略（双保险，socket 上另有 SO_NOSIGPIPE）：向已断开的隧道 TCP 连接写数据
// 时内核发 SIGPIPE，默认动作是静默终止 host——2026-08-20 实测两次无崩溃报告的暴毙根因。
signal(SIGPIPE, SIG_IGN)

// 单实例锁：显示器创建虽已集中到 shim + createDisplay 护栏，但两个 host 进程并存
// 仍意味着双份建销 churn（2026-08-20 调试实测踩过）。文件锁拿不到 = 已有实例，直接退出。
let singleInstanceFd = open("/tmp/hyperdisplay.host.lock", O_CREAT | O_RDWR, 0o644)
if singleInstanceFd < 0 || flock(singleInstanceFd, LOCK_EX | LOCK_NB) != 0 {
    NSLog("[hyperdisplay] another host instance is running (lock held) — exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = HostApp(config: config)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
