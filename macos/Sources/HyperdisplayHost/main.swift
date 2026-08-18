import Foundation
import AppKit

// MARK: - 配置

struct Config {
    var width = 1920
    var height = 1200
    var fps = 60
    var port: UInt16 = 5277
    var bitrate: UInt32 = 8_000_000

    static func parse(_ args: [String]) -> Config {
        var config = Config()
        var i = 1
        func intArg() -> Int? {
            i += 1
            guard i < args.count, let v = Int(args[i]) else { return nil }
            return v
        }
        while i < args.count {
            switch args[i] {
            case "--width": if let v = intArg() { config.width = min(max(640, v), 7680) }
            case "--height": if let v = intArg() { config.height = min(max(480, v), 4320) }
            case "--fps": if let v = intArg() { config.fps = [30, 60, 90, 144].first(where: { $0 >= v }) ?? 60 }
            case "--port": if let v = intArg() { config.port = UInt16(clamping: v) }
            case "--bitrate": if let v = intArg() { config.bitrate = UInt32(clamping: v) }
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

// MARK: - HostApp（菜单栏 app + 全链路串联）

final class HostApp: NSObject, NSApplicationDelegate {
    private let config: Config
    private var statusItem: NSStatusItem!

    private var virtualDisplay: VirtualDisplay?
    private var udp: UdpHost?
    private var capture: CaptureEngine?
    private var encoder: VideoEncoder?
    private let injector = InputInjector()

    private var streamingStarted = false
    private var startingStreaming = false
    private var frameId: UInt32 = 0
    private var lastKeyframeRequestAt = Date.distantPast
    private var lastEncodedSnapshot: UInt64 = 0
    private var effectiveFps: Int = 0

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
            self?.sampleStats()
        }
        RunLoop.main.add(statsTimer, forMode: .common)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: 启动链路

    private var permissionsGranted = false

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
        if virtualDisplay == nil {
            startPipeline()
        }
    }

    private func startPipeline() {
        guard let vd = VirtualDisplay(width: config.width, height: config.height, refreshRate: Double(config.fps)) else {
            NSLog("[hyperdisplay] virtual display creation failed — CGVirtualDisplay unavailable")
            return
        }
        virtualDisplay = vd
        NSLog("[hyperdisplay] host listening on UDP \(config.port); virtual display \(vd.displayID) ready")

        do {
            let udp = try UdpHost(port: config.port)
            udp.onPacket = { [weak self] packet, from in
                self?.handlePacket(packet, from: from)
            }
            udp.start()
            self.udp = udp
        } catch {
            NSLog("[hyperdisplay] \(error)")
            return
        }
        rebuildMenu()
    }

    private func handlePacket(_ packet: Packet, from addr: sockaddr_in) {
        switch packet {
        case .hello(let proto, let cw, let ch):
            udp?.setClientAddress(addr)
            NSLog("[hyperdisplay] HELLO proto=%d client=%dx%d from %@", proto, cw, ch, udp?.clientAddressString ?? "?")
            if !streamingStarted {
                startStreaming()
            } else {
                encoder?.requestKeyframe()
                if let vd = virtualDisplay {
                    injector.updateMapping(bounds: vd.bounds, streamWidth: Double(config.width), streamHeight: Double(config.height))
                }
                sendWelcome()
            }
        case .keyframeReq:
            // host 侧同样限频，防止 keyframe storm
            if Date().timeIntervalSince(lastKeyframeRequestAt) >= 0.5 {
                lastKeyframeRequestAt = Date()
                encoder?.requestKeyframe()
            }
        case .inputMove(let seq, let x, let y):
            injector.move(x: Double(x), y: Double(y))
            udp?.sendToClient(Wire.inputAck(seq: seq))
        case .inputButton(let seq, let button, let down, let x, let y):
            injector.button(button, down: down != 0, x: Double(x), y: Double(y))
            udp?.sendToClient(Wire.inputAck(seq: seq))
        case .inputWheel(let seq, let dx, let dy, let x, let y):
            injector.wheel(dx: Double(dx), dy: Double(dy), x: Double(x), y: Double(y))
            udp?.sendToClient(Wire.inputAck(seq: seq))
        case .ping(let seq):
            udp?.sendToClient(Wire.pong(seq: seq))
        }
    }

    private func startStreaming() {
        guard !startingStreaming, let vd = virtualDisplay, let udp else { return }
        startingStreaming = true

        let capture = CaptureEngine()
        capture.onFrame = { [weak self] pixelBuffer in
            self?.encoder?.encode(pixelBuffer: pixelBuffer)
        }
        self.capture = capture

        let encoder = VideoEncoder(
            onConfig: { [weak self] config in
                guard let self, let codec = self.encoder?.codec else { return }
                self.udp?.sendToClient(Wire.config(codec: codec.rawValue, frameId: self.frameId, paramSets: config))
            },
            onFrame: { [weak self] keyframe, payload in
                guard let self else { return }
                self.frameId &+= 1
                self.udp?.sendVideoFrame(frameId: self.frameId, keyframe: keyframe, payload: payload)
            }
        )
        self.encoder = encoder

        injector.updateMapping(bounds: vd.bounds, streamWidth: Double(config.width), streamHeight: Double(config.height))

        let cfg = config
        Task.detached { [weak self] in
            do {
                let codec = try encoder.start(width: cfg.width, height: cfg.height, fps: cfg.fps, bitrate: cfg.bitrate)
                try await capture.start(displayID: vd.displayID, width: cfg.width, height: cfg.height, fps: cfg.fps)
                await MainActor.run {
                    self?.streamingStarted = true
                    self?.startingStreaming = false
                    self?.sendWelcome(codec: codec)
                    self?.rebuildMenu()
                }
            } catch {
                NSLog("[hyperdisplay] startStreaming failed: \(error)")
                await MainActor.run {
                    self?.startingStreaming = false
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func sendWelcome(codec: VideoEncoder.Codec? = nil) {
        let c = codec ?? encoder?.codec ?? .hevc
        udp?.sendToClient(Wire.welcome(codec: c.rawValue, width: config.width, height: config.height, fps: config.fps))
    }

    // MARK: 菜单栏

    private func sampleStats() {
        if let encoder {
            let now = encoder.encodedFrames
            effectiveFps = Int(now - lastEncodedSnapshot)
            lastEncodedSnapshot = now
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
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
        if let vd = virtualDisplay {
            menu.addItem(withTitle: "虚拟屏: \(vd.pixelWidth)×\(vd.pixelHeight)@\(config.fps) · id \(vd.displayID)", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "虚拟屏: 创建失败（CGVirtualDisplay 不可用）", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "本机: \(Self.primaryIPv4() ?? "?") · UDP \(udp?.port ?? config.port)", action: nil, keyEquivalent: "")
        if let client = udp?.clientAddressString {
            menu.addItem(withTitle: "客户端: \(client)", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "客户端: 等待平板连接（手输上面的 IP:端口）", action: nil, keyEquivalent: "")
        }
        if streamingStarted {
            let codecName = encoder?.codec == .h264 ? "H.264" : "HEVC"
            menu.addItem(withTitle: "编码: \(codecName) · 请求 \(config.fps) FPS · 实测 \(effectiveFps) FPS", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出（虚拟屏自动销毁）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    @objc private func requestScreenPerm() {
        Permissions.requestScreenRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.stop()
        encoder?.stop()
    }

    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        var best: String?
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
            if name == "en0" { best = address; break }
            if fallback == nil { fallback = address }
        }
        return best ?? fallback
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
