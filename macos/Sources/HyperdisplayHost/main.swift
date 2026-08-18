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
    var displayId: CGDirectDisplayID
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
    // 近期关键帧的分片缓存（NACK 重传用；增量帧可丢不缓存）
    private var keyframeFragments: [UInt32: [Data]] = [:]
    private var keyframeOrder: [UInt32] = []
    private let fragLock = NSLock()

    init(display: VirtualDisplay, fps: Int, bitrate: UInt32, host: HostApp, udp: UdpHost) {
        self.display = display
        self.fps = fps
        self.bitrate = bitrate
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
                for var addr in self.host?.addressesOfSubscribers(of: self.display.displayID) ?? [] {
                    self.udp.send(to: &addr, Wire.config(codec: codec.rawValue, frameId: self.frameId, paramSets: config))
                }
            },
            onFrame: { [weak self] keyframe, payload in
                guard let self else { return }
                self.frameId &+= 1
                let addresses = self.host?.addressesOfSubscribers(of: self.display.displayID) ?? []
                let frags = Wire.videoFrags(frameId: self.frameId, keyframe: keyframe, payload: payload)
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
                for var addr in addresses {
                    for (index, frag) in frags.enumerated() {
                        self.udp.sendWithBackpressure(to: &addr, frag)
                        if index > 0 && index % 64 == 0 {
                            usleep(1500)
                        }
                    }
                }
            }
        )
        self.encoder = encoder
        injector.updateMapping(bounds: display.bounds, streamWidth: Double(display.pixelWidth), streamHeight: Double(display.pixelHeight))

        let bitrate = self.bitrate
        let forceH264 = host?.config.forceH264 ?? false
        Task.detached { [weak self] in
            do {
                let codec = try encoder.start(width: display.pixelWidth, height: display.pixelHeight, fps: fps, bitrate: bitrate, forceH264: forceH264)
                try await capture.start(displayID: display.displayID, width: display.pixelWidth, height: display.pixelHeight, fps: fps)
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
        let data = Wire.welcome(codec: c.rawValue, width: display.pixelWidth, height: display.pixelHeight, fps: fps)
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
        }
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
                _ = createDisplay(width: d.width, height: d.height, name: nextDisplayName())
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
        guard streams.count < 4 else {
            NSLog("[hyperdisplay] display limit (4) reached")
            return nil
        }
        guard let vd = VirtualDisplay(width: width, height: height, refreshRate: Double(config.fps)) else { return nil }
        guard let udp else { return nil }
        let stream = DisplayStream(
            display: vd, fps: config.fps,
            bitrate: config.bitrate ?? Config.autoBitrate(width: width, height: height),
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
            if clients[key]?.displayId == id { clients[key]?.displayId = displayOrder.first ?? 0 }
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
            let target = clients[key]?.displayId ?? (displayOrder.first ?? 0)
            clientsLock.lock()
            clients[key] = Client(addr: addr, displayId: target, lastSeen: Date())
            clientsLock.unlock()
            NSLog("[hyperdisplay] HELLO proto=\(proto) client=\(cw)x\(ch) from \(addressString(addr))")
            pushDisplays()
            subscribe(key: key, displayId: target)

        case .selectDisplay(let id):
            guard streams[CGDirectDisplayID(id)] != nil else { break }
            pushDisplays()
            subscribe(key: key, displayId: CGDirectDisplayID(id))

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
            if let fallback = displayOrder.first {
                subscribe(key: key, displayId: fallback)
            }

        case .keyframeReq:
            if let id = clients[key]?.displayId, let stream = streams[id] {
                stream.requestKeyframeAndReplay()
            }

        case .nack(let frameId, let indices):
            if let id = clients[key]?.displayId, let stream = streams[id] {
                stream.handleNack(frameId: frameId, indices: indices, to: addr)
            }

        case .inputMove(let seq, let x, let y):
            if let id = clients[key]?.displayId, let stream = streams[id] {
                if loggedInputClients.insert(key).inserted {
                    NSLog("[hyperdisplay] first input from \(addressString(addr)): move=(\(x), \(y)) display=\(id)")
                }
                stream.injector.move(x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .inputButton(let seq, let button, let down, let x, let y):
            if let id = clients[key]?.displayId, let stream = streams[id] {
                stream.injector.button(button, down: down != 0, x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .inputWheel(let seq, let dx, let dy, let x, let y):
            if let id = clients[key]?.displayId, let stream = streams[id] {
                stream.injector.wheel(dx: Double(dx), dy: Double(dy), x: Double(x), y: Double(y))
                var a = addr
                udp?.send(to: &a, Wire.inputAck(seq: seq))
            }

        case .ping(let seq):
            var a = addr
            udp?.send(to: &a, Wire.pong(seq: seq))
        }
    }

    private func subscribe(key: String, displayId: CGDirectDisplayID) {
        guard streams[displayId] != nil else { return }
        clientsLock.lock()
        clients[key]?.displayId = displayId
        clientsLock.unlock()
        streams[displayId]?.startIfNeeded()
        streams[displayId]?.sendWelcome()
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
        return clients.values.filter { $0.displayId == displayId }.map { $0.addr }
    }

    // MARK: 周期 tick：统计 + 客户端 prune

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
        for stream in streams.values {
            stream.sampleStats()
            if stream.started, addressesOfSubscribers(of: stream.display.displayID).isEmpty {
                stream.stop()
                NSLog("[hyperdisplay] stream stopped for display \(stream.display.displayID) (no subscribers)")
            }
        }
        rebuildMenu(clientCount: clientCount)
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
            let line = "屏 \(index + 1): \(s.display.pixelWidth)×\(s.display.pixelHeight) · id \(id)"
                + (s.started ? " · \(s.effectiveFps) fps · \(subscribers) 客户端" : " · 待客户端")
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
