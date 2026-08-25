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
    /// nil = 按分辨率自动（10Mbps/百万像素，8–60M 区间）
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
        // 画质优先（2026-08-21 用户定稿：局域网带宽不稀缺）：10Mbps/MP，
        // 8–60M 区间。旧 3.5Mbps/MP 是省带宽思维——运动帧糊、静止锐化 IDR
        // 被码率窗压小（109KB 不够锐）。提_base 后 IDR 自然变大（1s 窗上限
        // = 2×base，400KB IDR 轻松容纳），AIMD 仍按丢片率兜底下调。
        return UInt32(min(60, max(8, megapixels * 10))) * 1_000_000
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

/// 发行渠道配置：用户从菜单栏进入最新 GitHub Release，再按说明下载 Android APK。
/// 允许 fork 在打包时通过 Info.plist 覆盖，避免把运行时行为绑定到开发目录或 git remote。
enum ReleaseLinks {
    static let fallbackAndroidDownload = URL(string: "https://github.com/dyyz1993/hyperdisplay/releases/latest")!

    static var androidDownload: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HyperdisplayAndroidReleaseURL") as? String
        return configured.flatMap(URL.init(string:)) ?? fallbackAndroidDownload
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
    /// 用于在健康护栏解除后按原有 EDID 档案恢复同一块副屏。
    let deviceId: UInt32
    var displayIds: Set<CGDirectDisplayID> // 单屏=1个元素；分屏=多个
    var lastSeen: Date
}

/// 真实系统光标图像是低频、可靠的小控制状态：一个 imageId 可分成数个 UDP 包，
/// 由 ACK 驱动短暂重发；它绝不进入视频帧队列，避免旧样式堵住新画面。
private struct CursorImageSnapshot {
    let id: UInt32
    let packets: [Data]
    let hash: UInt64
}

private struct CursorImageDelivery {
    let id: UInt32
    var awaiting: Set<String>
    var attempts: Int
}

/// 一台平板的持久副屏档案。slot 是身份的一部分：同一台平板的第 1、2 块屏用
/// 不同但恒定的 EDID productID，macOS 才能分别记住各自的排列位置与窗口归属。
private struct DeviceScreenProfile: Codable, Equatable {
    let width: Int
    let height: Int
    let name: String
    let slot: Int
}

/// 设备槽位对应的全局桌面原点。分辨率档位变更不可避免会让 CGVirtualDisplay 对象
/// 重建；EDID 只让 macOS“尽量”记住，而该记录是我们自己的确定性兜底。
private struct DeviceScreenPlacement: Codable, Equatable {
    let slot: Int
    let x: Int32
    let y: Int32
}

private struct CanonicalDeviceIdentity {
    let deviceId: UInt32
    /// true 仅代表“指纹已有归属、这次安装内随机 ID 已变”，不能用 Android 的
    /// 单屏默认值覆盖 Host 已保存的多屏档案和布局。
    let restoredAfterReinstall: Bool
}

/// 一次设备拓扑变更的不可分割事务。CGVirtualDisplay 的注销是异步的：Swift/ObjC 已经
/// 释放对象，并不代表 WindowServer/ScreenCaptureKit 已停止枚举它。因此同一时刻全局只
/// 允许一个事务，且每块屏都要「出现 → 健康沉降」后才创建下一块。
private final class DeviceTopologyTransition {
    let deviceId: UInt32
    let profiles: [DeviceScreenProfile]
    let generation: UInt64
    var started = false
    var waitingForRemoval = false
    var cancelled = false
    var nextProfileIndex = 0
    var awaitingDisplayID: CGDirectDisplayID?
    var appearanceDeadline = Date.distantPast
    var screenCaptureCheckInFlight = false
    var screenCaptureVisible = false
    var healthGateUntil = Date.distantPast

    init(deviceId: UInt32, profiles: [DeviceScreenProfile], generation: UInt64) {
        self.deviceId = deviceId
        self.profiles = profiles
        self.generation = generation
    }
}

private struct DeviceTopologyRequest {
    let deviceId: UInt32
    let profiles: [DeviceScreenProfile]
    let generation: UInt64
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
    let name: String
    /// 该屏绑定的持久 Android 设备；nil 表示手动/临时屏。
    let deviceId: UInt32?
    /// 同一设备下的稳定屏幕序号（0-based）；nil 为手动临时屏。
    let screenSlot: Int?
    let fps: Int
    let bitrate: UInt32
    private weak var host: HostApp?
    private let udp: UdpHost

    private var capture: CaptureEngine?
    private var encoder: VideoEncoder?
    private var frameId: UInt32 = 0
    private var lastKeyframeRequestAt = Date.distantPast
    /// 静止锐化（2026-08-21）：内容驱动的编码下，画面停在哪帧就保持哪帧的质量——
    /// 运动末尾的帧是低质量帧（码率被运动分摊），静止后不重编码就永远糊着。
    /// 检测「动→静」转换（≥0.5s 无新帧）时重编码一帧全质量 IDR，客户端无感刷新
    /// 为清晰画面（macOS 自带屏幕共享的同款行为）。
    private var lastContentFrameAt: Date?
    private var refinementWasMoving = false
    private var starting = false
    private(set) var started = false
    private var captureStartedAt: Date?
    private var lastCaptureRestartAt = Date.distantPast
    private(set) var effectiveFps = 0
    private var encodedSnapshot: UInt64 = 0
    var idleSince: Date?          // 无订阅者起始时间（自动回收用）
    var isInitialDisplay = false  // 仅显式 --display 预建的诊断屏不参与自动回收
    private let fragLock = NSLock()
    /// 最近的 CONFIG 报文（编码参数集）：encoder 启动时只广播一次，之后接入的
    /// 订阅者必须补发——没有参数集解码器无法初始化，完整 IDR 也会被客户端丢弃
    /// （2026-08-21 端到端定位：IDR 258/258 片组装成功仍黑屏的根因）
    private var lastConfigPacket: Data?

    // MARK: 自适应画质（帧率优先：丢片时降码率；静止锐化/稳定网络时回升）
    private(set) var targetBitrate: UInt32
    /// 单屏时的画质目标。双屏时 `targetBitrate` 会被同一台平板的共享传输预算
    /// 压低，但这里保留原值用于诊断，避免“第二块屏出现后主屏仍沿用单屏峰值”。
    let qualityCeiling: UInt32
    private(set) var currentBitrate: UInt32
    private(set) var captureScale = 1.0
    private let bitrateFloor: UInt32 = 2_000_000
    private var fragmentsSentTotal: UInt64 = 0
    /// 完整帧被 Android 的 latest-frame 接收器放弃的次数。此前只有分片发送总数，
    /// 却从未把空 NACK 记入统计，导致 AIMD 永远看见“零丢失”。
    private var congestionEventsTotal: UInt64 = 0
    private var framesSentTotal: UInt64 = 0
    private var windowSentBase: UInt64 = 0
    private var windowFrameBase: UInt64 = 0
    private var windowCongestionBase: UInt64 = 0
    private var windowStart = Date()
    private var goodWindows = 0
    /// 平板报告「整帧已来不及收完」的最近时刻。这个信号比关键帧 NACK 更早，
    /// 所以稳定回升必须避开它，否则会形成每 4 秒重新冲高、每 4 秒再卡住的振荡。
    private var lastCongestionAt = Date.distantPast
    /// 运动画面优先平滑：不改虚拟屏/采集尺寸（该路径在此 macOS 虚拟屏上会绿屏），
    /// 只在 VideoToolbox 内降低实时码率；静止时仍恢复 qualityCeiling 的细节。
    private var motionBitrateActive = false

    init(display: VirtualDisplay, name: String, deviceId: UInt32? = nil, screenSlot: Int? = nil,
         fps: Int, bitrate: UInt32, host: HostApp, udp: UdpHost) {
        self.display = display
        self.name = name
        self.deviceId = deviceId
        self.screenSlot = screenSlot
        self.fps = fps
        self.bitrate = bitrate
        self.targetBitrate = bitrate
        self.qualityCeiling = bitrate
        // 先用可交付的实时预算起流。5MP 屏按画质上限直接以 50Mbps 启动时，第一张
        // HEVC IDR 可大到数百 UDP 分片；Wi-Fi 上只要少一片就没有可解码画面。静态
        // 画质仍由 targetBitrate 逐级恢复，但首帧和运动优先保证“先流畅、后变清晰”。
        self.currentBitrate = min(bitrate, 12_000_000)
        self.host = host
        self.udp = udp
    }

    private func wireCapture(_ capture: CaptureEngine) {
        capture.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            // 采集侧新鲜像素 = 真实内容活跃（静止锐化的唯一时间戳来源；编码侧
            // 重编码帧不算——见 makeEncoder 注释）。放在订阅门控之前：无人订阅时
            // 内容活跃与否的追踪也不该停（重新订阅后锐化检测需要正确基线）。
            self.lastContentFrameAt = Date()
            // 不只依赖 tick 恰好撞上「最近 300ms 有帧」的窗口。首次连上、窗口
            // 一次性绘制后立刻静止等场景也必须进入待锐化状态；否则会永远留在
            // 实时起流的低延迟画质，用户看到的就是“静态桌面一直不清晰”。
            self.refinementWasMoving = true
            self.enterMotionBitrateIfNeeded()
            if self.host?.addressesOfSubscribers(of: self.display.displayID).isEmpty ?? true {
                return // 订阅门控：无人看时不编码；宽限到期后 tick 会停流并销毁屏
            }
            // 只在编码前执行 latest-frame 丢弃。不能把已经编码的 P 帧在 UDP 队列
            // 中覆盖，否则下一张 P 帧的引用链会断，平板会停住等待 IDR。
            guard self.udp.canAcceptVideoFrame(streamId: UInt32(self.display.displayID)) else { return }
            self.encoder?.encode(pixelBuffer: pixelBuffer)
        }
        capture.onReplayFrame = { [weak self] pixelBuffer in
            // 重放只为把已有静态帧编码成 IDR；不得改动 lastContentFrameAt，也不应
            // 触发运动码率档位。
            self?.encoder?.encode(pixelBuffer: pixelBuffer)
        }
    }

    /// 运动期的起始预算：约 5Mbps/MP、5–12Mbps。当前 1440×960 约为 7Mbps；
    /// 足以在 Wi-Fi 上保持 60fps，又比静态质量上限少一半左右的 UDP 分片。
    private func motionBitrateCap() -> UInt32 {
        let megapixels = Double(display.logicalWidth * display.logicalHeight) / 1_000_000
        let proposed = UInt32(max(5, min(12, megapixels * 5))) * 1_000_000
        return max(bitrateFloor, min(targetBitrate, proposed))
    }

    private func enterMotionBitrateIfNeeded() {
        guard !motionBitrateActive else { return }
        motionBitrateActive = true
        let cap = motionBitrateCap()
        guard currentBitrate > cap else { return }
        currentBitrate = cap
        encoder?.applyBitrate(cap)
        NSLog("[hyperdisplay] motion bitrate -> \(cap / 1000)kbps display=\(display.displayID)")
    }

    /// SCK 停流看门狗：macOS 26 虚拟屏上 SCStream 会偶发永久静默（连 idle 事件都停发，
    /// 实测会话开始 30s 内即可发生），客户端将冻在最后一帧且永不自愈。
    /// 有订阅者但 2.5s 零事件 → 只重建采集流（编码器会话不动——重开 VideoToolbox
    /// 会触发华为硬解绿屏），重启后等 idle 帧填充缓存再补关键帧（客户端仍显示
    /// 旧帧，无黑闪）。
    /// 同一块屏的采集流重启是唯一允许的自动恢复路径；绝不升级为重建虚拟屏，
    /// 避免 ColorSync churn。注意不能用"有帧到达"清零——每次重启后 SCK 常
    /// 回光返照吐一两帧又死，帧计数永远到不了阈值。
    private var captureRestartTimes: [Date] = []
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
            // 当前显示器生命周期内只保留这一条流；不升级为重建虚拟屏。
            // 只记录，交给同流 restart 继续尝试。
            NSLog("[hyperdisplay] capture stuck through \(captureRestartTimes.count) restarts on display \(display.displayID) (immortal-stream mode: no escalation)")
            captureRestartTimes.removeLast()
        }
        lastCaptureRestartAt = now
        NSLog("[hyperdisplay] capture watchdog: display \(display.displayID) silent \(Int(silent))s — restarting capture")
        // 同一显示器生命周期内优先重启原 SCStream，避免新建流的偶发静默。
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

    /// 创建编码器（含 CONFIG 缓存/广播与分片平滑发送的完整接线）。
    /// startIfNeeded 与 bounceEncoder 共用——闭包只引用 self，无本地捕获。
    private func makeEncoder() -> VideoEncoder {
        VideoEncoder(
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
                // 注意：不在此更新 lastContentFrameAt——编码产出的帧包含 replay 回放
                // 和 applyBitrate 触发的 IDR（同一画面的重编码，非新内容）。时间戳
                // 由采集侧（wireCapture 的新鲜帧）更新，否则锐化/AIMD 的重编码帧
                // 会互相重新武装对方 → 码率战争死循环（2026-08-21 实测三连修）
                let addresses = self.host?.addressesOfSubscribers(of: self.display.displayID) ?? []
                let did = UInt16(self.display.displayID & 0xFFFF)
                let frags = Wire.videoFrags(displayId: did, frameId: self.frameId, keyframe: keyframe, payload: payload)
                fragLock.lock()
                self.fragmentsSentTotal &+= UInt64(frags.count)
                self.framesSentTotal &+= 1
                fragLock.unlock()
                // 平滑发送不能变成“人为排队”：此前普通 P 帧最多被摊到 70ms，双屏
                // 连续滚动时单 socket 实际只能交付十几帧，Android 每次跳帧又必须等
                // IDR，用户看起来就是秒级延迟。接收端已有 4MB UDP 缓冲；把增量帧
                // 限在 8ms 内、IDR 限在 90ms 内，既避免瞬时倾倒，又给下一张最新
                // 帧留下发送时间。UdpHost 仍保证同一屏的一帧分片不交错。
                let fragCount = frags.count
                // IDR 可以比 P 帧慢，但恢复锚点若传 350ms，再叠加一次帧缺口/请求
                // 节流就会重新落入 1–2 秒冻结。90ms 是 Wi-Fi 下的恢复上限，而非
                // 目标发送时间；小帧仍按实际分片数缩短。
                let framePacingUs = keyframe
                    ? min(90_000, max(20_000, fragCount * 180))
                    : min(8_000, max(2_000, fragCount * 60))
                let perFragDelay: useconds_t = fragCount > 1
                    ? useconds_t(framePacingUs / fragCount)
                    : 0
                for var addr in addresses {
                    // USB 隧道客户端（127.0.0.1，经 UsbTunnelController 桥接）：跳过
                    // usleep 节流——有线无损，节流只在编码回调/发送队列上白阻塞加延迟；
                    // Wi-Fi 才需要防突发打爆接收缓冲。
                    let isTunnel = addr.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian
                    self.udp.enqueueVideoFrame(streamId: UInt32(self.display.displayID), to: addr,
                                               fragments: frags, keyframe: keyframe,
                                               perFragmentDelay: isTunnel ? 0 : perFragDelay)
                }
            }
        )
    }

    /// 只重建编码器会话（绿屏自愈的最后手段，客户端 ENCODER_RESET 触发）：
    /// VideoToolbox 会话经会话切换风暴后可能产出全零流（华为硬解渲染为纯绿），
    /// 客户端重建解码器无效——必须换掉 host 侧编码器。不碰当前 SCStream/虚拟屏。
    func bounceEncoder() {
        guard started else { return }
        NSLog("[hyperdisplay] bouncing encoder for display \(display.displayID)")
        encoder?.stop()
        let newEncoder = makeEncoder()
        encoder = newEncoder
        let scale = captureScale
        let w = max(640, Int(Double(display.logicalWidth) * scale))
        let h = max(480, Int(Double(display.logicalHeight) * scale))
        let fps = self.fps
        let bitrate = currentBitrate
        let forceH264 = host?.config.forceH264 ?? false
        Task.detached { [weak self] in
            do {
                let codec = try newEncoder.start(width: w, height: h, fps: fps, bitrate: bitrate, forceH264: forceH264)
                await MainActor.run {
                    // onConfig 已向订阅者广播新参数集；补 Welcome（含 codec）+ 关键帧
                    self?.sendWelcome(codec: codec)
                    self?.requestKeyframeAndReplay()
                }
            } catch {
                NSLog("[hyperdisplay] encoder bounce failed: \(error)")
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

        let encoder = makeEncoder()
        self.encoder = encoder
        let scale = captureScale
        let scaledW = max(640, Int(Double(display.logicalWidth) * scale))
        let scaledH = max(480, Int(Double(display.logicalHeight) * scale))

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
        let w = max(640, Int(Double(display.logicalWidth) * scale))
        let h = max(480, Int(Double(display.logicalHeight) * scale))
        let data = Wire.welcome(codec: c.rawValue, displayId: did, width: w, height: h, fps: fps,
                                controlEnabled: false)
        for var addr in host?.addressesOfSubscribers(of: display.displayID) ?? [] {
            udp.send(to: &addr, data)
        }
    }

    func requestKeyframeAndReplay() {
        // 丢掉一个 P 帧后，华为 HEVC 不能继续解码，只能等 IDR。这里是恢复路径
        // 而不是常规 GOP：250ms 的去重上限可将一帧缺口恢复在亚秒内，同时避免
        // Android 每个分片都触发重编码风暴。
        guard Date().timeIntervalSince(lastKeyframeRequestAt) >= 0.25 else { return }
        lastKeyframeRequestAt = Date()
        encoder?.requestKeyframe()
        capture?.replayLastFrame()
    }

    /// 同一平板订阅多块屏时由 Host 统一调用。此处不改虚拟屏、不重启采集/编码器，
    /// 因而不会引入 ColorSync churn；只把正在运行的 VideoToolbox 会话收敛到预算内。
    func setTransportTargetBitrate(_ value: UInt32) {
        let next = max(bitrateFloor, min(qualityCeiling, value))
        guard next != targetBitrate else { return }
        targetBitrate = next
        if currentBitrate > next {
            currentBitrate = next
            encoder?.applyBitrate(next)
        }
        NSLog("[hyperdisplay] transport budget display=\(display.displayID) target=\(next/1000)kbps ceiling=\(qualityCeiling/1000)kbps")
    }

    /// 空 NACK 不是“重传 0 个分片”，而是 Android 的聚合拥塞反馈：latest-frame
    /// 接收器已经放弃了整帧，再补数百片只会让下一帧也死掉。运动优先时直接乘法降速。
    func noteCongestion(now: Date = Date()) {
        fragLock.lock()
        congestionEventsTotal &+= 1
        fragLock.unlock()
        guard started, now.timeIntervalSince(lastCongestionAt) >= 1.5 else { return }
        lastCongestionAt = now
        goodWindows = 0
        guard currentBitrate > bitrateFloor else { return }
        currentBitrate = max(bitrateFloor, currentBitrate * 2 / 3)
        encoder?.applyBitrate(currentBitrate)
        NSLog("[hyperdisplay] quality: receiver congested -> \(currentBitrate/1000)kbps display=\(display.displayID)")
    }

    /// 静止锐化入口（tick 每秒调）：内容静止 ≥0.5s 且此前在动 → 重编码 IDR。
    /// 运动末帧是低质量帧（码率被运动分摊 + AIMD 可能已砍码率），不重编码就糊着
    /// 停在屏幕上。锐化帧**无视 AIMD 直接用满目标码率**：静止单帧是一次性开销，
    /// 不占持续带宽（LAN 带宽不稀缺原则，AGENTS §7.5）——修「停止后 10s 才恢复」
    /// 的根因（旧逻辑锐化帧沿用被砍码率 + AIMD 12s/步爬回）。
    /// 限频：每次运动周期只锐化一次。
    func refineIfSettled(now: Date) {
        guard let last = lastContentFrameAt else { return }
        let still = now.timeIntervalSince(last)
        if still < 0.3 {
            refinementWasMoving = true
        } else if still > 0.5 && refinementWasMoving {
            refinementWasMoving = false
            motionBitrateActive = false // 下一次真实内容到来立刻重新进入运动档
            let saved = currentBitrate
            let sourceFrameAt = last
            if saved < targetBitrate {
                encoder?.applyBitrate(targetBitrate) // 满码率编码这一帧
            }
            NSLog("[hyperdisplay] refinement IDR for display \(display.displayID) (settled; bitrate \(saved/1000)k->\(targetBitrate/1000)k)")
            requestKeyframeAndReplay()
            // 防自触发循环：IDR 编码/replay 都会更新 lastContentFrameAt（立即清空会被
            // 自己的回放帧填回，实测循环仍存）。1.5s 后（IDR 已编码送达）再清空 +
            // 还原码率——此后只有真实新采集内容才会重新武装锐化检测。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // 这 1.5 秒内若出现了新的真实采集帧，用户已重新滚动：运动回调已
                // 负责降档，不能再把旧静态事务的低码率/空时间戳写回去。
                guard self.lastContentFrameAt == sourceFrameAt else { return }
                self.lastContentFrameAt = nil
                if saved < self.targetBitrate, self.currentBitrate == self.targetBitrate {
                    self.encoder?.applyBitrate(saved)
                }
            }
        }
    }

    /// 视频不做分片重传：NACK 的非空形式可能来自旧客户端，直接当作“这一帧已过期”
    /// 处理，重编码一张最新 IDR。补旧包会和正在滚动的新画面抢同一个 UDP 队列。
    func handleNack(frameId: UInt32, indices: [UInt16], to addr: sockaddr_in) {
        _ = (frameId, indices, addr)
        noteCongestion()
        requestKeyframeAndReplay()
    }

    func sampleStats() {
        guard let encoder else { return }
        let now = encoder.snapshotEncodedFrames()
        // 流重启后新会话计数从小值开始，直接按当前计数处理，避免无符号下溢
        effectiveFps = now >= encodedSnapshot ? Int(min(now - encodedSnapshot, 100_000)) : Int(min(now, 100_000))
        encodedSnapshot = now
    }

    /// 帧率优先的自适应画质：以 Android 实际放弃整帧的事件为准。原先的“丢片数”
    /// 从未递增，因而这条保护等于失效；连续两个 2 秒窗口零拥塞才逐级回升。
    func adaptQuality(now: Date) {
        guard started else { return }
        guard now.timeIntervalSince(windowStart) >= 2.0 else { return }
        fragLock.lock()
        let sent = fragmentsSentTotal - windowSentBase
        let frames = framesSentTotal - windowFrameBase
        let congestions = congestionEventsTotal - windowCongestionBase
        windowSentBase = fragmentsSentTotal
        windowFrameBase = framesSentTotal
        windowCongestionBase = congestionEventsTotal
        fragLock.unlock()
        windowStart = now

        guard sent > 300, frames >= 20 else { return } // 窗口内流量太小，不具备统计意义

        if congestions > 0 {
            goodWindows = 0
            // noteCongestion 已立即乘法降档；这里仅确保不会把网络尚在拥塞的窗口
            // 误判为稳定并回升，避免一次事件在同一窗口被重复砍两次码率。
            NSLog("[hyperdisplay] quality: \(congestions) receiver-congestion event(s) / \(frames) frames display=\(display.displayID)")
            // 采集缩放降档已禁用：macOS 26 上对虚拟屏的缩放采集（SCK width/height < 屏幕原生）
            // 会输出全绿帧（实测）。分辨率适配改由「重建更小的虚拟屏」实现（待做），
            // 当前分辨率始终与虚拟屏 1:1。
        } else if now.timeIntervalSince(lastCongestionAt) >= 6.0 {
            goodWindows += 1
            if goodWindows >= 4 { // 至少 8 秒未见整帧拥塞才小步回升，避免双屏运动时振荡。
                goodWindows = 0
                if currentBitrate < targetBitrate {
                    currentBitrate = min(targetBitrate, currentBitrate * 6 / 5)
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
    private var statusBarIcon: NSImage?

    private var udp: UdpHost?
    /// USB 隧道桥 + adb reverse 轮询（AGENTS.md §1 有线例外：TCP 仅限此路径）
    private let usbTunnel = UsbTunnelController()
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
    private var screenRecordingGranted = false
    /// 若本进程启动时未获屏幕录制，TCC 要求重启后才能把新授权交给采集路径。
    private let screenRecordingWasMissingAtLaunch: Bool
    private var restartForScreenRecordingPending = false
    private var currentDeviceId: UInt32 = 0
    private var displaySerial = 0
    /// 设备档案：一台平板可有一块默认屏或一组分屏；同时缓存在内存和 UserDefaults。
    private var deviceProfiles: [UInt32: [DeviceScreenProfile]] = [:]
    /// 平板发送的是不可逆的系统指纹，绝不落盘原始 Android ID。这个映射让卸载重装
    /// 后新生成的会话 ID 继续归属于同一份档案/EDID/桌面坐标。
    private var deviceFingerprintMappings: [String: UInt32] = [:]
    /// 仅在建/销显示器或正常退出时读写；日常串流完全不访问磁盘。
    private var devicePlacements: [UInt32: [DeviceScreenPlacement]] = [:]
    /// 显示器拓扑不是网络包的同步副作用。HELLO/断线/改布局只更新期望状态，实际
    /// CGVirtualDisplay 生命周期由这一个串行事务编排，避免旧屏尚未注销就创建新屏。
    private var pendingTopologyRequests: [UInt32: DeviceTopologyRequest] = [:]
    private var activeTopologyTransition: DeviceTopologyTransition?
    private var topologyGeneration: UInt64 = 0
    /// 已显式销毁、但尚出现在 CGGetActiveDisplayList 的显示器。只要这里非空，绝不
    /// 创建任意新虚拟屏；这比盲等固定秒数更可靠，也避免 USB/后台抖动造成身份竞态。
    private var displayRemovalBarrier: Set<CGDirectDisplayID> = []
    /// 上次建屏失败时刻：1s 退避，防客户端（弱网重连风暴）把主线程打成重试死循环
    private var lastCreateFailAt: Date?
    /// ColorSync 护栏拒绝后最多每 30 秒再检查一次；不能把“等待恢复”做成每秒 ps
    /// 和建屏重试循环，否则监控本身也会制造负载。
    private var nextWaitingRestoreAt = Date.distantPast
    /// 新建 CGVirtualDisplay 后仅在短窗口内加密采样。私有 API 的异常往往不是
    /// 创建前就可见，而是在 WindowServer 注册新显示器后的几秒内才暴露。
    private var postCreateColorSyncCheckUntil = Date.distantPast
    private var nextPostCreateColorSyncCheckAt = Date.distantPast
    private var postCreateColorSyncHighStreak = 0
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
    private let permissionPanel = PermissionPanelController()
    private let displayHealth = DisplayHealthMonitor()
    private let processResources = ProcessResourceMonitor()
    private var lastMenuRefreshAt = Date.distantPast
    /// 最近已推送的光标状态。仅位置实际改变时发 UDP，避免 30Hz 空包常驻。
    private var lastCursorKey = ""
    /// 样式读取最多 12Hz，且仅在鼠标位于某块虚拟屏、存在订阅者时启用。
    private var lastCursorImagePollAt = Date.distantPast
    private var cursorImageReaderFailures = 0
    private var cursorImageReaderDisabled = false
    private var nextCursorImageId: UInt32 = 1
    private let cursorImageLock = NSLock()
    private var cachedCursorImage: CursorImageSnapshot?
    private var cursorImageDelivery: CursorImageDelivery?

    init(config: Config) {
        self.config = config
        self.screenRecordingWasMissingAtLaunch = !Permissions.hasScreenRecording()
        super.init()
        permissionPanel.onRestartRequested = { [weak self] in
            self?.restartAfterScreenRecordingPermission()
        }
        permissionPanel.onPermissionDetected = { [weak self] in
            self?.pollPermissionsAndStart()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        loadStatusBarIcon()
        setStatusItemState("Hyperdisplay")
        rebuildMenu()

        let permissionTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollPermissionsAndStart()
        }
        RunLoop.main.add(permissionTimer, forMode: .common)
        pollPermissionsAndStart()

        let statsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(statsTimer, forMode: .common)

        // 纯显示模式也应看到 Mac 的真实指针，但绝不注入/控制它。无客户端时
        // pushCursorPosition 直接空返回，符合闲时近零成本的约束。
        // 鼠标和 60Hz 视频不同：它只有一个极小 UDP 坐标包，不能因为视频的
        // 内容驱动采样而降到 30Hz。按显示刷新率采样，平板端再按 VSync 合成，
        // 快速移动时不会出现明显的「台阶感」。静止时 lastCursorKey 会抑制发送。
        let cursorTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pushCursorPosition()
        }
        RunLoop.main.add(cursorTimer, forMode: .common)

    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: 启动

    private func pollPermissionsAndStart() {
        if !screenRecordingGranted {
            let screen = Permissions.hasScreenRecording()
            guard screen else {
                setStatusItemState("需要屏幕录制权限", marker: "!")
                permissionPanel.showScreenRecordingRequired()
                return
            }
            screenRecordingGranted = true
            // 运行中新增的屏幕录制授权不能热接入 SCK：必须以干净的新进程启动。
            if screenRecordingWasMissingAtLaunch {
                restartForScreenRecordingPending = true
                permissionPanel.showScreenRecordingRestartRequired()
                return
            }
            permissionPanel.close()
        }
        if restartForScreenRecordingPending {
            permissionPanel.showScreenRecordingRestartRequired()
            return
        }
        refreshStatusIcon()
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
            refreshStatusIcon()
            // 健康首采样完成后再广播服务，确保 ColorSync 已热时客户端 HELLO 不会
            // 抢在硬门槛建立之前触发建屏。
            let hostName = Host.current().localizedName ?? "Mac"
            _ = bonjour.start(name: "Hyperdisplay (\(hostName))", port: udp.port,
                              txt: ["code": String(pairingCode)])
            // USB 隧道桥 + adb reverse 轮询（零点击：插线即用，AGENTS.md §7.1）。
            // adb 不存在时只打一条日志——Wi-Fi 路径完全不受影响。
            usbTunnel.onDeviceCountChange = { [weak self] in self?.rebuildMenu() }
            usbTunnel.start(udpPort: udp.port)
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

    private func profileDefaultsKey(_ deviceId: UInt32) -> String {
        "hyperdisplay.deviceScreens.\(deviceId)"
    }

    private func placementDefaultsKey(_ deviceId: UInt32) -> String {
        "hyperdisplay.devicePlacements.\(deviceId)"
    }

    private func layoutDefaultsKey(_ deviceId: UInt32) -> String {
        "hyperdisplay.deviceLayout.\(deviceId)"
    }

    private var deviceFingerprintDefaultsKey: String { "hyperdisplay.deviceFingerprintMappings.v1" }

    private func deviceFingerprintKey(_ fingerprint: UInt64) -> String {
        String(format: "%016llx", fingerprint)
    }

    private func loadDeviceFingerprintMappingsIfNeeded() {
        guard deviceFingerprintMappings.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: deviceFingerprintDefaultsKey),
              let saved = try? JSONDecoder().decode([String: UInt32].self, from: data) else { return }
        deviceFingerprintMappings = saved
    }

    /// 将临时安装 ID 解析为 Host 侧的规范设备身份。指纹仅用于本地查表，绝不参与
    /// EDID 或日志；最终的 EDID 仍由稳定 canonical ID 决定。
    private func canonicalDeviceIdentity(claimedId: UInt32, fingerprint: UInt64) -> CanonicalDeviceIdentity {
        guard claimedId != 0, fingerprint != 0 else {
            return CanonicalDeviceIdentity(deviceId: claimedId, restoredAfterReinstall: false)
        }
        loadDeviceFingerprintMappingsIfNeeded()
        let key = deviceFingerprintKey(fingerprint)
        if let canonical = deviceFingerprintMappings[key] {
            return CanonicalDeviceIdentity(deviceId: canonical, restoredAfterReinstall: canonical != claimedId)
        }
        deviceFingerprintMappings[key] = claimedId
        if let data = try? JSONEncoder().encode(deviceFingerprintMappings) {
            UserDefaults.standard.set(data, forKey: deviceFingerprintDefaultsKey)
        }
        NSLog("[hyperdisplay] registered stable device identity for existing display profile")
        return CanonicalDeviceIdentity(deviceId: claimedId, restoredAfterReinstall: false)
    }

    private func loadDeviceLayout(_ deviceId: UInt32) -> DeviceLayoutState? {
        guard let data = UserDefaults.standard.data(forKey: layoutDefaultsKey(deviceId)) else { return nil }
        return try? JSONDecoder().decode(DeviceLayoutState.self, from: data)
    }

    private func saveDeviceLayout(_ deviceId: UInt32, _ layout: DeviceLayoutState) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: layoutDefaultsKey(deviceId))
    }

    private func loadDevicePlacements(_ deviceId: UInt32) -> [DeviceScreenPlacement] {
        if let cached = devicePlacements[deviceId] { return cached }
        let loaded: [DeviceScreenPlacement]
        if let data = UserDefaults.standard.data(forKey: placementDefaultsKey(deviceId)),
           let decoded = try? JSONDecoder().decode([DeviceScreenPlacement].self, from: data) {
            loaded = Array(decoded.sorted { $0.slot < $1.slot }.prefix(4))
        } else {
            loaded = []
        }
        devicePlacements[deviceId] = loaded
        return loaded
    }

    /// 必须在释放 CGVirtualDisplay 对象前调用；之后 WindowServer 只会给出新屏的
    /// 默认位置，已经无法推回用户原先的排列。
    private func snapshotDevicePlacements(deviceId: UInt32) {
        let placements = streams.values.compactMap { stream -> DeviceScreenPlacement? in
            guard stream.deviceId == deviceId, let slot = stream.screenSlot else { return nil }
            let bounds = stream.display.bounds
            return DeviceScreenPlacement(slot: slot,
                                         x: Int32(clamping: Int(bounds.minX)),
                                         y: Int32(clamping: Int(bounds.minY)))
        }.sorted { $0.slot < $1.slot }
        guard !placements.isEmpty else { return }
        devicePlacements[deviceId] = placements
        guard let data = try? JSONEncoder().encode(placements) else { return }
        UserDefaults.standard.set(data, forKey: placementDefaultsKey(deviceId))
        NSLog("[hyperdisplay] saved \(placements.count) display placement(s) for device \(deviceId)")
    }

    /// WindowServer 和 SCK 都确认新屏可用后才写原点。使用 session 级公开 API：
    /// 不碰显示模式、不新建对象，下一次重连仍由我们持久化档案再次恢复。
    private func restoreDevicePlacement(displayID: CGDirectDisplayID, deviceId: UInt32, slot: Int) {
        guard let placement = loadDevicePlacements(deviceId).first(where: { $0.slot == slot }) else { return }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            NSLog("[hyperdisplay] could not begin placement restore for display \(displayID)")
            return
        }
        guard CGConfigureDisplayOrigin(configuration, displayID, placement.x, placement.y) == .success else {
            CGCancelDisplayConfiguration(configuration)
            NSLog("[hyperdisplay] could not configure placement restore for display \(displayID)")
            return
        }
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
            NSLog("[hyperdisplay] placement restore completion failed for display \(displayID)")
            return
        }
        NSLog("[hyperdisplay] restored display \(displayID) slot \(slot) to (\(placement.x),\(placement.y))")
    }

    private func loadDeviceProfiles(_ deviceId: UInt32) -> [DeviceScreenProfile]? {
        if let cached = deviceProfiles[deviceId], !cached.isEmpty { return cached }
        if let data = UserDefaults.standard.data(forKey: profileDefaultsKey(deviceId)),
           let decoded = try? JSONDecoder().decode([DeviceScreenProfile].self, from: data),
           !decoded.isEmpty {
            let normalized = decoded.sorted { $0.slot < $1.slot }.prefix(4).map { $0 }
            deviceProfiles[deviceId] = normalized
            return normalized
        }
        // 兼容上一版单屏档位落盘；新格式会在本次成功连接后覆盖它。
        let tierKey = "hyperdisplay.tier.\(deviceId)"
        if let saved = UserDefaults.standard.string(forKey: tierKey),
           let w = saved.split(separator: ",").first.flatMap({ Int($0) }),
           let h = saved.split(separator: ",").last.flatMap({ Int($0) }), w >= 640, h >= 480 {
            let legacy = [DeviceScreenProfile(width: w, height: h,
                                              name: "Hyperdisplay 设备 \(deviceId % 10000)", slot: 0)]
            deviceProfiles[deviceId] = legacy
            return legacy
        }
        return nil
    }

    private func saveDeviceProfiles(_ deviceId: UInt32, _ profiles: [DeviceScreenProfile]) {
        let safe = Array(profiles.sorted { $0.slot < $1.slot }.prefix(4))
        guard !safe.isEmpty, let data = try? JSONEncoder().encode(safe) else { return }
        deviceProfiles[deviceId] = safe
        UserDefaults.standard.set(data, forKey: profileDefaultsKey(deviceId))
    }

    private func makeProfiles(deviceId: UInt32, specs: [RequestedDisplaySpec]) -> [DeviceScreenProfile] {
        specs.prefix(4).enumerated().map { index, spec in
            let w = max(640, (Int(spec.width) + 15) & ~15)
            let h = max(480, (Int(spec.height) + 15) & ~15)
            let suffix = specs.count > 1 ? " · 屏 \(index + 1)" : ""
            return DeviceScreenProfile(width: w, height: h,
                                       name: "Hyperdisplay 设备 \(deviceId % 10000)\(suffix)", slot: index)
        }
    }

    private func deviceProfiles(deviceId: UInt32, clientWidth: UInt16, clientHeight: UInt16,
                                requested: [RequestedDisplaySpec]) -> [DeviceScreenProfile] {
        // 平板自身已保存的布局是最近一次用户选择；新 HELLO 带它即表示主动恢复/更新。
        // 没有尾部规格的旧客户端才优先使用 Mac 上已落盘的档案。
        if !requested.isEmpty {
            let profiles = makeProfiles(deviceId: deviceId, specs: requested)
            if loadDeviceProfiles(deviceId) != profiles { saveDeviceProfiles(deviceId, profiles) }
            return profiles
        }
        if let saved = loadDeviceProfiles(deviceId) { return saved }
        let fallback = makeProfiles(deviceId: deviceId,
                                    specs: [RequestedDisplaySpec(width: clientWidth, height: clientHeight)])
        saveDeviceProfiles(deviceId, fallback)
        return fallback
    }

    /// 显示器拓扑只有设备档案这一个权威来源。平板重连时，如果槽位和尺寸完全一致，
    /// 直接复用现有屏；否则只登记目标拓扑，交给单队列按「旧屏完全消失 → 新屏出现
    /// → 健康沉降」执行。禁止客户端逐块 CREATE/DESTROY，避免一次 UI 刷新放大成
    /// WindowServer/ColorSync churn。
    private func reconcileDeviceDisplays(deviceId: UInt32, profiles: [DeviceScreenProfile]) {
        if let active = activeTopologyTransition, active.deviceId == deviceId {
            guard active.profiles != profiles else { return }
            // 新 HELLO 代表更晚的用户意图。正在创建的旧布局不再继续扩张；已创建的
            // 部分会走同一条显式销毁 + 消失确认路径，绝不交叠创建。
            active.cancelled = true
        } else if pendingTopologyRequests[deviceId]?.profiles == profiles {
            return
        } else if topologyMatchesCurrentStreams(deviceId: deviceId, profiles: profiles) {
            NSLog("[hyperdisplay] device \(deviceId) reconnected → reusing \(profiles.count) remembered display(s)")
            return
        }

        topologyGeneration &+= 1
        pendingTopologyRequests[deviceId] = DeviceTopologyRequest(
            deviceId: deviceId, profiles: profiles, generation: topologyGeneration)
        advanceTopologyTransition()
    }

    private func topologyMatchesCurrentStreams(deviceId: UInt32,
                                                profiles: [DeviceScreenProfile]) -> Bool {
        let existing = streams.filter { $0.value.deviceId == deviceId }
        return existing.count == profiles.count && profiles.allSatisfy { profile in
            guard let stream = existing.first(where: { $0.value.screenSlot == profile.slot })?.value else {
                return false
            }
            return stream.display.logicalWidth == profile.width &&
                   stream.display.logicalHeight == profile.height
        }
    }

    /// `CGGetActiveDisplayList` 是唯一可用于确认 WindowServer 已放下旧显示器的低层
    /// 证据。销毁对象后不等固定秒数：系统快就立刻继续，系统慢就保持零 churn 等待。
    private func refreshDisplayRemovalBarrier() {
        guard !displayRemovalBarrier.isEmpty else { return }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let active = Set(ids.prefix(Int(count)))
        displayRemovalBarrier = displayRemovalBarrier.intersection(active)
    }

    private func removeDeviceDisplays(deviceId: UInt32) {
        snapshotDevicePlacements(deviceId: deviceId)
        let ids = streams.filter { $0.value.deviceId == deviceId }.map(\.key)
        for id in ids { destroyDisplay(id: id, allowLast: true) }
    }

    private func cancelTopology(for deviceId: UInt32) {
        pendingTopologyRequests.removeValue(forKey: deviceId)
        if let active = activeTopologyTransition, active.deviceId == deviceId {
            active.cancelled = true
        }
    }

    /// 同一时刻只能有一个 `CGVirtualDisplay` 拓扑事务。每秒由 tick 驱动，正常空闲时
    /// 零额外线程/子进程；只有用户连接、改分屏或断开后重开才进入这里。
    private func advanceTopologyTransition(now: Date = Date()) {
        refreshDisplayRemovalBarrier()

        if let active = activeTopologyTransition {
            if active.cancelled {
                if !active.waitingForRemoval {
                    removeDeviceDisplays(deviceId: active.deviceId)
                    active.waitingForRemoval = true
                    active.appearanceDeadline = now.addingTimeInterval(15)
                    return
                }
                if displayRemovalBarrier.isEmpty {
                    activeTopologyTransition = nil
                    advanceTopologyTransition(now: now)
                } else if now > active.appearanceDeadline {
                    NSLog("[hyperdisplay] topology cancellation timed out waiting for display removal; holding creation")
                    activeTopologyTransition = nil
                    nextWaitingRestoreAt = now.addingTimeInterval(300)
                }
                return
            }

            if !active.started {
                active.started = true
                let existing = streams.filter { $0.value.deviceId == active.deviceId }
                if !existing.isEmpty {
                    removeDeviceDisplays(deviceId: active.deviceId)
                    active.waitingForRemoval = true
                    active.appearanceDeadline = now.addingTimeInterval(15)
                    return
                }
            }

            if active.waitingForRemoval {
                guard displayRemovalBarrier.isEmpty else {
                    if now > active.appearanceDeadline {
                        NSLog("[hyperdisplay] topology rebuild timed out waiting for WindowServer to remove old display(s); no retry for 5 minutes")
                        pendingTopologyRequests[active.deviceId] = DeviceTopologyRequest(
                            deviceId: active.deviceId, profiles: active.profiles,
                            generation: active.generation)
                        activeTopologyTransition = nil
                        nextWaitingRestoreAt = now.addingTimeInterval(300)
                    }
                    return
                }
                active.waitingForRemoval = false
            }

            if let displayID = active.awaitingDisplayID {
                if displayRemovalBarrier.contains(displayID) || !isDisplayActive(displayID) {
                    if now > active.appearanceDeadline {
                        NSLog("[hyperdisplay] created display \(displayID) never appeared; stopping automatic topology retry")
                        removeDeviceDisplays(deviceId: active.deviceId)
                        pendingTopologyRequests[active.deviceId] = DeviceTopologyRequest(
                            deviceId: active.deviceId, profiles: active.profiles,
                            generation: active.generation)
                        activeTopologyTransition = nil
                        nextWaitingRestoreAt = now.addingTimeInterval(300)
                    }
                    return
                }
                // CGGetActiveDisplayList 可见还不代表 ScreenCaptureKit 已经完成枚举。
                // 只有二者均可见才放行下一块屏；否则第二次创建可能与 SCK 注册竞态。
                if !active.screenCaptureVisible {
                    if !active.screenCaptureCheckInFlight {
                        active.screenCaptureCheckInFlight = true
                        requestScreenCaptureVisibility(for: displayID,
                                                       deviceId: active.deviceId,
                                                       generation: active.generation)
                    }
                    if now > active.appearanceDeadline {
                        NSLog("[hyperdisplay] display \(displayID) never appeared in ScreenCaptureKit; stopping automatic topology retry")
                        removeDeviceDisplays(deviceId: active.deviceId)
                        pendingTopologyRequests[active.deviceId] = DeviceTopologyRequest(
                            deviceId: active.deviceId, profiles: active.profiles,
                            generation: active.generation)
                        activeTopologyTransition = nil
                        nextWaitingRestoreAt = now.addingTimeInterval(300)
                    }
                    return
                }
                if let slot = streams[displayID]?.screenSlot {
                    restoreDevicePlacement(displayID: displayID, deviceId: active.deviceId, slot: slot)
                }
                active.awaitingDisplayID = nil
                // 第一块屏一旦同时被 WindowServer 与 ScreenCaptureKit 确认，就可以先
                // 交给平板出画。后续屏仍在 ColorSync 观察窗口里串行创建，不要让主屏
                // 为画中画的第二块屏白等 8 秒。
                attachDeviceDisplaysToConnectedClients(deviceId: active.deviceId)
                // 多屏的下一块必须等当前屏通过完整 ColorSync 观察窗口。这样第二块若
                // 触发系统 bug，会停在已验证的一块而不是并发制造更多显示器事件。
                active.healthGateUntil = max(postCreateColorSyncCheckUntil, now.addingTimeInterval(8))
                return
            }

            guard now >= active.healthGateUntil else { return }
            if active.nextProfileIndex < active.profiles.count {
                let profile = active.profiles[active.nextProfileIndex]
                guard let id = createDisplay(width: profile.width, height: profile.height,
                                             name: profile.name, deviceId: active.deviceId,
                                             screenSlot: profile.slot,
                                             colorSyncPreflighted: true) else {
                    NSLog("[hyperdisplay] topology creation failed for \(profile.name); stopping automatic retry")
                    removeDeviceDisplays(deviceId: active.deviceId)
                    pendingTopologyRequests[active.deviceId] = DeviceTopologyRequest(
                        deviceId: active.deviceId, profiles: active.profiles,
                        generation: active.generation)
                    activeTopologyTransition = nil
                    nextWaitingRestoreAt = now.addingTimeInterval(300)
                    return
                }
                active.nextProfileIndex += 1
                active.awaitingDisplayID = id
                active.appearanceDeadline = now.addingTimeInterval(15)
                active.screenCaptureCheckInFlight = false
                active.screenCaptureVisible = false
                NSLog("[hyperdisplay] topology \(active.generation) created \(profile.name) id=\(id); waiting for WindowServer")
                return
            }

            let deviceId = active.deviceId
            activeTopologyTransition = nil
            attachDeviceDisplaysToConnectedClients(deviceId: deviceId)
            NSLog("[hyperdisplay] topology \(active.generation) restored \(active.profiles.count) display(s) for device \(deviceId)")
            advanceTopologyTransition(now: now)
            return
        }

        guard displayRemovalBarrier.isEmpty, now >= nextWaitingRestoreAt else { return }
        guard let request = pendingTopologyRequests.values.min(by: { $0.generation < $1.generation }) else { return }
        guard colorSyncAllowsDisplayCreation() else { return }
        pendingTopologyRequests.removeValue(forKey: request.deviceId)
        activeTopologyTransition = DeviceTopologyTransition(
            deviceId: request.deviceId, profiles: request.profiles, generation: request.generation)
        advanceTopologyTransition(now: now)
    }

    private func isDisplayActive(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains(id)
    }

    private func requestScreenCaptureVisibility(for displayID: CGDirectDisplayID,
                                                deviceId: UInt32, generation: UInt64) {
        Task { @MainActor [weak self] in
            let visible = await CaptureEngine.isDisplayVisibleToScreenCaptureKit(displayID: displayID)
            guard let self,
                  let active = self.activeTopologyTransition,
                  active.deviceId == deviceId,
                  active.generation == generation,
                  active.awaitingDisplayID == displayID else { return }
            active.screenCaptureCheckInFlight = false
            active.screenCaptureVisible = visible
        }
    }

    /// 异步完成拓扑后，将同一平板的所有活跃 UDP 会话订阅到新屏。初始 HELLO 在
    /// WindowServer 尚未注册显示器时会暂时得到空列表，因此这一步不能依赖客户端再点一次。
    private func attachDeviceDisplaysToConnectedClients(deviceId: UInt32) {
        let ids = Set(streams.filter { $0.value.deviceId == deviceId }.map(\.key))
        guard !ids.isEmpty else { return }
        clientsLock.lock()
        let keys = clients.compactMap { key, client -> String? in
            guard client.deviceId == deviceId else { return nil }
            clients[key]?.displayIds = ids
            return key
        }
        clientsLock.unlock()
        pushDisplays()
        for key in keys {
            for id in ids { subscribe(key: key, displayId: id) }
        }
    }

    // MARK: 显示器注册表（主线程访问）

    /// `CGVirtualDisplay` 是私有 API，且系统在异常会话上可能持续高负载。每一次
    /// 新建都必须从一个真正安静的 ColorSync 状态开始；不能沿用“低于 50% 就继续”。
    private func colorSyncAllowsDisplayCreation() -> Bool {
        let liveColorSync = DisplayHealthMonitor.colorSyncLoad()
        let liveColorSyncCPU = liveColorSync.peak
        guard displayHealth.level == .normal,
              let liveColorSyncCPU,
              liveColorSyncCPU < 1.0 else {
            NSLog("[hyperdisplay] refusing virtual-display creation: ColorSync is not quiescent (\(liveColorSync.description)); log out before retrying")
            return false
        }
        return true
    }

    private func createDisplay(width: Int, height: Int, name: String, deviceId: UInt32? = nil,
                               screenSlot: Int? = nil,
                               colorSyncPreflighted: Bool = false) -> CGDirectDisplayID? {
        // 同一份用户档案的多块屏共享一次预检；这样不会在已开始的受控组建过程中，
        // 因瞬时采样把布局留成半组。任何新一轮拓扑仍必须先通过静态预检。
        guard colorSyncPreflighted || colorSyncAllowsDisplayCreation() else { return nil }
        guard displayHealth.mayCreateDisplay() else {
            NSLog("[hyperdisplay] refusing virtual-display creation: hourly churn budget exhausted")
            return nil
        }
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
        // 舒适上限只对「无自定义档位」的默认路径生效（调用方 newProfileDefault 已
        // 压过 1920）；用户显式选的档位（SET_TIER 落盘，含 2240 锐利档）原样生效——
        // 在这里二次压档会把锐利档吃掉，实测用户切档"无变化"的根因（2026-08-21）
        let w = w0, h = h0
        // EDID 身份必须同时满足两件事：同一 slot 跨重连恒定（macOS 才能记住排列），
        // 不同 slot 并发时唯一（否则 WindowServer/ColorSync 会把两块逻辑屏误归并）。
        // slot 0 保留历史 serial/product，避免已保存的单屏排列被当成新显示器；slot>0
        // 使用独立的稳定编码，不再与 slot 0 或其他并发屏共享 serial。
        let slot = UInt32(max(0, screenSlot ?? 0))
        let serial: UInt32
        if let deviceId {
            if slot == 0 {
                serial = 1000 + (deviceId & 0xFFFF)
            } else {
                serial = 0x8000_0000 | ((deviceId & 0x07FF_FFFF) << 4) | (slot & 0x0F)
            }
        } else {
            serial = 1
        }
        let productID: UInt32 = deviceId == nil ? 0x0001 : 0x0001 + slot
        guard let vd = VirtualDisplay(width: w, height: h, refreshRate: Double(config.fps),
                                      productID: productID, serial: serial) else {
            lastCreateFailAt = Date()
            return nil
        }
        displayHealth.recordCreation() // churn 预算统计（AGENTS 4.1.2 运行时版）
        guard let udp else { return nil }
        // 初始值保持单屏的画质目标；插入注册表后会立即按设备组重新平衡。
        // 旧逻辑只把“新建的第二屏”除以流数，主屏还留在单屏峰值（51M + 6M），
        // 是双屏时平板 UDP 队列被打满的直接原因。
        let baseBitrate = config.bitrate ?? Config.autoBitrate(width: width, height: height)
        let stream = DisplayStream(
            display: vd, name: name, deviceId: deviceId, screenSlot: screenSlot, fps: config.fps,
            bitrate: baseBitrate,
            host: self, udp: udp)
        streamsLock.lock()
        streams[vd.displayID] = stream
        streamsLock.unlock()
        displayOrder.append(vd.displayID) // DISPLAYS 列表源；丢失 = 客户端收不到屏列表 = 黑屏（2026-08-21 定位回归）
        if let deviceId { rebalanceDeviceTransportBudget(deviceId: deviceId) }
        // 常态保持 30 秒一次低成本监控；仅建屏后 8 秒内每秒检查一次。如果系统
        // 因该私有 API 进入异常循环，快速回收本次新建对象，避免留给用户一个高 CPU 的“可用”副屏。
        let now = Date()
        postCreateColorSyncCheckUntil = max(postCreateColorSyncCheckUntil, now.addingTimeInterval(8))
        postCreateColorSyncHighStreak = 0
        let firstCheck = now.addingTimeInterval(1)
        nextPostCreateColorSyncCheckAt = nextPostCreateColorSyncCheckAt < now
            ? firstCheck
            : min(nextPostCreateColorSyncCheckAt, firstCheck)
        return vd.displayID
    }

    /// 双屏共用同一条 Android Wi-Fi/USB UDP 路径，必须按“设备总预算”而不是每路各自
    /// 用单屏峰值。16Mbps 是启动预算：真实拥塞仍由接收端反馈继续 AIMD 下调；静止时
    /// 单帧 IDR 可在各路自身目标内恢复清晰，不会持续抢占队列。
    private func rebalanceDeviceTransportBudget(deviceId: UInt32) {
        let deviceStreams = streams.values
            .filter { $0.deviceId == deviceId }
            .sorted { ($0.screenSlot ?? 0) < ($1.screenSlot ?? 0) }
        guard deviceStreams.count > 1 else { return }

        let floor: UInt64 = 2_000_000
        let desired = deviceStreams.map { UInt64($0.qualityCeiling) }
        let desiredTotal = desired.reduce(0, +)
        let budget = min(UInt64(16_000_000), desiredTotal)
        let remaining = max(UInt64(0), budget - floor * UInt64(deviceStreams.count))
        let weights = desired.map { max(UInt64(1), $0 - floor) }
        let weightTotal = weights.reduce(0, +)

        for (index, stream) in deviceStreams.enumerated() {
            let allocated = UInt32(min(UInt64(UInt32.max), floor + remaining * weights[index] / weightTotal))
            stream.setTransportTargetBitrate(allocated)
        }
        NSLog("[hyperdisplay] dual-screen shared transport budget=\(budget/1_000_000)Mbps device=\(deviceId)")
    }

    /// allowLast=true：闲置回收允许清到零屏（菜单手动移除仍保留最后一块护栏）
    private func destroyDisplay(id: CGDirectDisplayID, allowLast: Bool = false) {
        guard streams[id] != nil, allowLast || streams.count > 1 else { return }
        streams[id]?.stop()
        streams[id]?.display.destroy()
        // ObjC shim 已放开对象，也仍须等待 WindowServer 真正注销这个 id，才能创建下一块。
        displayRemovalBarrier.insert(id)
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
        // 高频包（ping/nack/keyframeReq/bye 轻路径）在接收线程直接处理：
        // 逐包 async 主线程会在包洪峰（多客户端×心跳×输入×NACK）下把主 RunLoop 的
        // Timer 全部饿死——tick/哨兵/看门狗停摆、进程"假死"（2026-08-20 实测定位）。
        // 这些 handler 只碰锁保护的 clients / streams 快照 / udp 发送，
        // 天然线程安全；会话变更类（HELLO/SELECT/SUBSCRIBE/CREATE/DESTROY）
        // 仍走主线程 async（低频、且要碰 CG/菜单）。
        switch packet {
        case .ping(let seq):
            let key = clientKey(addr)
            let liveDisplayIDs = Set(snapshotStreams().keys)
            clientsLock.lock()
            clients[key]?.lastSeen = Date()
            // 仅“来源地址还在 clients 字典”不代表会话可用：Host 重启、BYE 回收或
            // 拓扑失败后可能留下空订阅。旧逻辑仍回 known=true，平板便只发 PING、
            // 永远不再发 HELLO，造成“等待 Mac 主机”的自愈死锁。没有一块仍存活的
            // 订阅屏就明确回 unknown；Android 重发 HELLO，而 topology 去重保证不会
            // 因每 1.5 秒心跳制造 CGVirtualDisplay churn。
            let known = clients[key]?.displayIds.contains(where: { liveDisplayIDs.contains($0) }) == true
            clientsLock.unlock()
            var a = addr
            udp?.send(to: &a, Wire.pong(seq: seq, known: known))
        case .nack(let displayId, let frameId, let indices):
            if let stream = snapshotStreams()[CGDirectDisplayID(displayId)] {
                if indices.isEmpty {
                    // Android 端 latest-frame 放弃整帧后的轻量拥塞信号；不可重传。
                    // 以前这里只降码率；若已在码率地板，根本不会产生新的 IDR，
                    // Android 的安全解码器就要等它自己的 1 秒重试，轻微丢帧被放大
                    // 成 1–2 秒的画面冻结。立即回放最新采集帧并强制 IDR，仍由 250ms
                    // 限流保护，且不重建 SCK/虚拟显示器。
                    DispatchQueue.main.async {
                        stream.noteCongestion()
                        stream.requestKeyframeAndReplay()
                    }
                } else {
                    stream.handleNack(frameId: frameId, indices: indices, to: addr)
                }
            }
        // 产品收敛为纯外置显示器：不申请辅助功能，也绝不把平板事件注入 macOS。
        // 仍确认旧客户端的可靠输入包，避免它们因未收到 ACK 制造重传风暴。
        case .inputMove(_, let seq, _, _),
             .inputButton(_, let seq, _, _, _, _),
             .inputWheel(_, let seq, _, _, _, _):
            var a = addr
            udp?.send(to: &a, Wire.inputAck(seq: seq))
        case .keyframeReq(let displayId):
            let snapshot = snapshotStreams()
            if displayId == displayIdBroadcast {
                for stream in snapshot.values {
                    stream.requestKeyframeAndReplay()
                }
            } else if let stream = snapshot[CGDirectDisplayID(displayId)] {
                stream.requestKeyframeAndReplay()
            }
        case .cursorImageAck(let imageId):
            acknowledgeCursorImage(imageId: imageId, clientKey: clientKey(addr))
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
        case .hello(let proto, let cw, let ch, let code, let claimedDeviceId, let requestedDisplays, let deviceFingerprint, let layout):
            guard code == pairingCode else {
                NSLog("[hyperdisplay] HELLO from \(addressString(addr)) REJECTED (bad pairing code)")
                return
            }
            if proto == 0xFF {
                // 探针 HELLO（UsbProbe 链路检测）：只回声不注册——注册会订阅屏，
                // 周期性充电探测会把闲置回收卡死（显示永远"有人订着"）。
                // 放在配对码校验之后：错误码的探针拿不到回声，客户端探测如实失败。
                var a = addr
                udp?.send(to: &a, Wire.pong(seq: 0, known: false))
                return
            }
            let identity = canonicalDeviceIdentity(claimedId: claimedDeviceId, fingerprint: deviceFingerprint)
            let deviceId = identity.deviceId
            currentDeviceId = deviceId
            // 每个 HELLO 携带该平板上次保存的目标屏幕组。首次只带当前平板尺寸，
            // Host 因此直接建一块默认屏；之后若用户选过分屏，则一次复建完整两块/多块。
            if deviceId != 0 {
                if !identity.restoredAfterReinstall, let layout { saveDeviceLayout(deviceId, layout) }
                let profiles = deviceProfiles(deviceId: deviceId, clientWidth: cw, clientHeight: ch,
                                              requested: identity.restoredAfterReinstall ? [] : requestedDisplays)
                reconcileDeviceDisplays(deviceId: deviceId, profiles: profiles)
            }
            // 目标屏：档案屏优先（剪枝后重入会也能回到自己的屏——setSubscriptions 对
            // 不存在的客户端是空操作，不能依赖它），其次既有订阅，最后默认屏
            var targets: Set<CGDirectDisplayID> = []
            if deviceId != 0 {
                targets = Set(streams.filter { $0.value.deviceId == deviceId }.map(\.key))
            } else if let e = clients[key]?.displayIds, !e.isEmpty {
                targets = e
            } else if let first = displayOrder.first {
                targets = [first]
            }
            clientsLock.lock()
            clients[key] = Client(addr: addr, deviceId: deviceId, displayIds: targets, lastSeen: Date())
            clientsLock.unlock()
            if identity.restoredAfterReinstall, let savedLayout = loadDeviceLayout(deviceId) {
                var target = addr
                udp?.send(to: &target, Wire.savedLayout(savedLayout))
                NSLog("[hyperdisplay] restored remembered layout after client reinstall")
            }
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

        case .createDisplay, .destroyDisplay:
            // v1 的显示器数量/尺寸只允许随 HELLO 中保存的设备档案恢复。
            // 忽略旧客户端的自由建销指令，防止不受控的 ColorSync churn。
            NSLog("[hyperdisplay] ignored legacy direct display mutation from \(addressString(addr))")

        case .keyframeReq, .nack, .inputMove, .inputButton, .inputWheel, .ping, .cursorImageAck:
            break // 已在接收线程直接处理（见 handlePacket），主线程不再走

        case .encoderReset(let displayId):
            // 绿屏自愈最后手段（客户端检测到全零输出且本地解码器重建无效）：
            // 只重建该屏的编码器会话——不碰当前 SCStream/虚拟屏，
            // 2026-08-21 拔线绿屏实测：客户端 2 次自救失败后走此路径
            NSLog("[hyperdisplay] encoder reset requested for display \(displayId)")
            streams[CGDirectDisplayID(displayId)]?.bounceEncoder()

        case .setTier:
            // 新客户端会把尺寸写进 HELLO 档案后执行一次受控重连；不再为档位切换重启 Host。
            NSLog("[hyperdisplay] ignored legacy SET_TIER; waiting for profile-driven HELLO")

        case .bye:
            // 平板真正进入后台/退出就是物理拔线：立即销毁这台设备的整组虚拟屏。
            // USB↔Wi-Fi 换路由不会发 BYE，因此仍可在短暂断链窗口复用原屏。
            NSLog("[hyperdisplay] client \(addressString(addr)) said bye")
            clientsLock.lock()
            let deviceId = clients[key]?.deviceId
            clients.removeValue(forKey: key)
            clientsLock.unlock()
            if let deviceId, deviceId != 0 {
                let count = streams.values.filter { $0.deviceId == deviceId }.count
                cancelTopology(for: deviceId)
                removeDeviceDisplays(deviceId: deviceId)
                NSLog("[hyperdisplay] background unplug removed \(count) display(s) for device \(deviceId)")
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
        sendCachedCursorImage(to: key)
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
        sendCachedCursorImage(to: key)
        _ = removed // 移除的屏在 tick 中因无订阅者自动停流
    }

    private func pushDisplays() {
        let entries = displayListEntries()
        clientsLock.lock()
        let recipients = clients.values.map { ($0.addr, $0.deviceId) }
        clientsLock.unlock()
        for (var addr, deviceId) in recipients {
            // 设备会话只看到自己的档案屏；这样 canonical ID 与新安装的临时 ID 不同
            // 时，Android 也不会误把其他平板/手动屏选作“自己的第一块屏”。
            let visible = deviceId == 0 ? entries : entries.filter { entry in
                streams[CGDirectDisplayID(entry.id)]?.deviceId == deviceId
            }
            let data = Wire.displaysList(visible)
            udp?.send(to: &addr, data)
        }
    }

    private func displayListEntries() -> [DisplayListEntry] {
        let entries = displayOrder.compactMap { (id: CGDirectDisplayID) -> DisplayListEntry? in
            guard let s = streams[id] else { return nil }
            return DisplayListEntry(
                id: UInt32(id),
                width: UInt16(s.display.logicalWidth),
                height: UInt16(s.display.logicalHeight),
                name: s.name)
        }
        return entries
    }

    func addressesOfSubscribers(of displayId: CGDirectDisplayID) -> [sockaddr_in] {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.values.filter { $0.displayIds.contains(displayId) }.map { $0.addr }
    }

    private func cursorImageRecipients(of displayId: CGDirectDisplayID) -> [(String, sockaddr_in)] {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.compactMap { key, client in
            client.displayIds.contains(displayId) ? (key, client.addr) : nil
        }
    }

    private func addresses(for keys: Set<String>) -> [sockaddr_in] {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return keys.compactMap { clients[$0]?.addr }
    }

    private func sendCursorImagePackets(_ packets: [Data], to addresses: [sockaddr_in]) {
        guard let udp else { return }
        for address in addresses {
            var addr = address
            for packet in packets { udp.send(to: &addr, packet) }
        }
    }

    /// 读取与发送完全不创建 SCStream/虚拟屏。私有读取连续三次失败即进程级熔断，
    /// 平板继续使用现有本地箭头，避免任何系统版本差异影响主显示功能。
    private func pollCursorImageIfNeeded(recipients: [(String, sockaddr_in)]) {
        guard !cursorImageReaderDisabled, !recipients.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCursorImagePollAt) >= (1.0 / 12.0) else { return }
        lastCursorImagePollAt = now

        var width: UInt16 = 0, height: UInt16 = 0
        var hotX: Int16 = 0, hotY: Int16 = 0
        var hash: UInt64 = 0
        guard let pixels = hyperdisplayCopyCurrentCursorImage(&width, &height, &hotX, &hotY, &hash) as Data?,
              pixels.count == Int(width) * Int(height) * 4,
              !pixels.isEmpty else {
            cursorImageReaderFailures += 1
            if cursorImageReaderFailures >= 3 {
                cursorImageReaderDisabled = true
                NSLog("[hyperdisplay] cursor image reader disabled after 3 safe failures; using local arrow")
            }
            return
        }
        cursorImageReaderFailures = 0
        cursorImageLock.lock()
        let unchanged = cachedCursorImage?.hash == hash
        cursorImageLock.unlock()
        guard !unchanged else { return }

        let imageId = nextCursorImageId
        nextCursorImageId &+= 1
        let packets = Wire.cursorImage(imageId: imageId, width: width, height: height,
                                       hotX: hotX, hotY: hotY, pixels: pixels)
        guard !packets.isEmpty else { return }
        let recipientKeys = Set(recipients.map(\.0))
        cursorImageLock.lock()
        cachedCursorImage = CursorImageSnapshot(id: imageId, packets: packets, hash: hash)
        cursorImageDelivery = CursorImageDelivery(id: imageId, awaiting: recipientKeys, attempts: 1)
        cursorImageLock.unlock()
        sendCursorImagePackets(packets, to: recipients.map(\.1))
        scheduleCursorImageRetry(imageId: imageId)
    }

    private func sendCachedCursorImage(to key: String) {
        cursorImageLock.lock()
        guard let cached = cachedCursorImage else { cursorImageLock.unlock(); return }
        var delivery = cursorImageDelivery ?? CursorImageDelivery(id: cached.id, awaiting: [], attempts: 0)
        guard delivery.id == cached.id else { cursorImageLock.unlock(); return }
        delivery.awaiting.insert(key)
        delivery.attempts = 0
        cursorImageDelivery = delivery
        cursorImageLock.unlock()
        sendCursorImagePackets(cached.packets, to: addresses(for: [key]))
        scheduleCursorImageRetry(imageId: cached.id)
    }

    private func acknowledgeCursorImage(imageId: UInt32, clientKey key: String) {
        cursorImageLock.lock()
        defer { cursorImageLock.unlock() }
        guard var delivery = cursorImageDelivery, delivery.id == imageId else { return }
        delivery.awaiting.remove(key)
        cursorImageDelivery = delivery.awaiting.isEmpty ? nil : delivery
    }

    private func scheduleCursorImageRetry(imageId: UInt32) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            self?.retryCursorImageIfNeeded(imageId: imageId)
        }
    }

    private func retryCursorImageIfNeeded(imageId: UInt32) {
        cursorImageLock.lock()
        guard var delivery = cursorImageDelivery, delivery.id == imageId,
              let cached = cachedCursorImage, cached.id == imageId,
              !delivery.awaiting.isEmpty else { cursorImageLock.unlock(); return }
        guard delivery.attempts < 3 else {
            cursorImageDelivery = nil
            cursorImageLock.unlock()
            return
        }
        delivery.attempts += 1
        cursorImageDelivery = delivery
        let packets = cached.packets
        let awaiting = delivery.awaiting
        cursorImageLock.unlock()
        sendCursorImagePackets(packets, to: addresses(for: awaiting))
        scheduleCursorImageRetry(imageId: imageId)
    }

    /// 读取系统光标位置是只读操作，不触发辅助功能权限。CGEvent.location 与
    /// CGDisplayBounds 在同一套全局桌面坐标中；SCK 输出也沿用该显示方向，
    /// 不能再翻转 Y（旧实现已在真机验证过）。
    private func pushCursorPosition() {
        guard let udp else { return }
        clientsLock.lock()
        let allClients = clients.values.map { $0.addr }
        clientsLock.unlock()
        guard !allClients.isEmpty else {
            lastCursorKey = ""
            return
        }
        guard let location = CGEvent(source: nil)?.location else { return }

        for id in displayOrder {
            guard let stream = streams[id] else { continue }
            let bounds = stream.display.bounds
            guard location.x >= bounds.minX, location.x < bounds.maxX,
                  location.y >= bounds.minY, location.y < bounds.maxY else { continue }
            let subscribers = addressesOfSubscribers(of: id)
            guard !subscribers.isEmpty else { continue }
            let cursorImageRecipients = cursorImageRecipients(of: id)
            let x = Float((location.x - bounds.minX) / bounds.width * CGFloat(stream.display.logicalWidth))
            let y = Float((location.y - bounds.minY) / bounds.height * CGFloat(stream.display.logicalHeight))
            let key = "\(id):\(Int(x)),\(Int(y))"
            if key != lastCursorKey {
                lastCursorKey = key
                let packet = Wire.cursor(displayId: UInt16(id & 0xFFFF), x: x, y: y)
                for var addr in subscribers { udp.send(to: &addr, packet) }
            }
            pollCursorImageIfNeeded(recipients: cursorImageRecipients)
            return
        }

        // 进入其他物理显示器后马上让平板隐藏叠加箭头；只发一次离开事件。
        guard lastCursorKey != "off" else { return }
        lastCursorKey = "off"
        let packet = Wire.cursor(displayId: 0, x: 0, y: 0)
        for var addr in allClients { udp.send(to: &addr, packet) }
    }

    // MARK: 周期 tick：统计 + 客户端 prune

    private func tick() {
        let now = Date()
        _ = processResources.sampleIfDue(now: now)
        enforcePostCreateColorSyncGuard(now: now)
        advanceTopologyTransition(now: now)
        clientsLock.lock()
        let stale = clients.filter { now.timeIntervalSince($0.value.lastSeen) > 6 }.map { $0.key }
        for key in stale { clients.removeValue(forKey: key) }
        let clientCount = clients.count
        clientsLock.unlock()
        if !stale.isEmpty {
            NSLog("[hyperdisplay] pruned \(stale.count) stale client(s)")
        }
        restoreWaitingDisplayIfHealthy()
        // 有会话期间每屏只保留一条 SCStream；看门狗只重启同一流。无人订阅后按
        // 产品基线回收：BYE 约 5s，异常断链从最后心跳算约 15s。严禁因此做全量重建。
        var expired: [CGDirectDisplayID] = []
        for stream in Array(streams.values) {
            stream.sampleStats()
            stream.adaptQuality(now: now)
            if addressesOfSubscribers(of: stream.display.displayID).isEmpty {
                if stream.idleSince == nil {
                    // stale 客户端在 6s 时被剪枝；回拨这 6s，使异常总回收时长约 15s。
                    stream.idleSince = stale.isEmpty ? now : now.addingTimeInterval(-6)
                }
                if !stream.isInitialDisplay,
                   let since = stream.idleSince,
                   now.timeIntervalSince(since) >= 15 {
                    expired.append(stream.display.displayID)
                }
            } else {
                stream.idleSince = nil
                stream.restartCaptureIfNeeded(now: now)
                stream.refineIfSettled(now: now) // 静止锐化：动→静转换时重编码全质量 IDR
            }
        }
        if !expired.isEmpty {
            for id in expired { destroyDisplay(id: id, allowLast: true) }
            NSLog("[hyperdisplay] idle GC destroyed \(expired.count) display(s); remaining=\(streams.count)")
            pushDisplays()
        }
        // 菜单关闭时无需每秒重建整棵 NSMenu（含多屏子菜单和地址枚举）。
        // 5 秒一次与资源采样同频，连接/权限/显示器事件仍会即时主动刷新。
        if now.timeIntervalSince(lastMenuRefreshAt) >= 5 {
            lastMenuRefreshAt = now
            rebuildMenu(clientCount: clientCount)
        }
    }

    /// 创建前 CPU 正常不等于创建后系统不会陷入 ColorSync 循环。这个熔断器只针对
    /// 刚建的屏：连续三次 >20% 才删除，避免把一个瞬时注册尖峰误判为系统中毒；
    /// 触发后不自动重试，用户必须在系统恢复后主动再次连接。
    /// 空闲或稳定串流不会运行额外采样，避免“为了监控而常驻耗电”。
    private func enforcePostCreateColorSyncGuard(now: Date) {
        guard now <= postCreateColorSyncCheckUntil else {
            postCreateColorSyncHighStreak = 0
            return
        }
        guard now >= nextPostCreateColorSyncCheckAt else { return }
        nextPostCreateColorSyncCheckAt = now.addingTimeInterval(1)
        let load = DisplayHealthMonitor.colorSyncLoad()
        guard let cpu = load.peak else { return }
        postCreateColorSyncHighStreak = cpu > 20 ? postCreateColorSyncHighStreak + 1 : 0
        guard postCreateColorSyncHighStreak >= 3 else { return }
        let cutoff = now.addingTimeInterval(-15)
        let ids = streams.compactMap { id, stream in stream.display.createdAt >= cutoff ? id : nil }
        guard !ids.isEmpty else { return }
        NSLog("[hyperdisplay] emergency ColorSync guard: \(load.description) for \(postCreateColorSyncHighStreak)s after virtual-display creation; removing \(ids.count) new display(s) and stopping automatic retry")
        let affectedDevices = Set(ids.compactMap { streams[$0]?.deviceId })
        for deviceId in affectedDevices {
            pendingTopologyRequests.removeValue(forKey: deviceId)
            if activeTopologyTransition?.deviceId == deviceId {
                activeTopologyTransition?.cancelled = true
            }
        }
        for id in ids { destroyDisplay(id: id, allowLast: true) }
        postCreateColorSyncCheckUntil = .distantPast
        postCreateColorSyncHighStreak = 0
        nextWaitingRestoreAt = now.addingTimeInterval(300)
        pushDisplays()
    }

    /// ColorSync 保护期间，HELLO 会被保留为已连接会话但不建屏。健康恢复后必须由
    /// host 主动补建：Android 会保持同一个 UDP socket 等待，不能要求用户退出再打开。
    /// v1 只有单平板，因此一次只恢复一个等待中的设备；成功后即停止，避免任何
    /// "恢复循环"演变成显示器 churn。
    private func restoreWaitingDisplayIfHealthy() {
        let now = Date()
        guard now >= nextWaitingRestoreAt, streams.isEmpty, displayHealth.level == .normal else { return }
        nextWaitingRestoreAt = now.addingTimeInterval(30)
        clientsLock.lock()
        let waiting = clients.first { _, client in
            client.deviceId != 0 && client.displayIds.isEmpty && loadDeviceProfiles(client.deviceId) != nil
        }
        clientsLock.unlock()
        guard let (key, client) = waiting, let profiles = loadDeviceProfiles(client.deviceId) else { return }
        reconcileDeviceDisplays(deviceId: client.deviceId, profiles: profiles)
        let restored = Set(streams.filter { $0.value.deviceId == client.deviceId }.map(\.key))
        guard !restored.isEmpty else { return }
        clientsLock.lock()
        if clients[key] != nil { clients[key]?.displayIds = restored }
        clientsLock.unlock()
        NSLog("[hyperdisplay] ColorSync recovered — restored \(restored.count) display(s) for waiting client")
        pushDisplays()
        for id in restored { subscribe(key: key, displayId: id) }
    }

    // MARK: 菜单栏

    private func loadStatusBarIcon() {
        guard let url = Bundle.main.url(forResource: "HyperdisplayMenuBar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        statusBarIcon = image
    }

    private func setStatusItemState(_ toolTip: String, marker: String? = nil) {
        guard let button = statusItem?.button else { return }
        button.toolTip = toolTip
        if let statusBarIcon {
            button.image = statusBarIcon
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = marker == nil ? .imageOnly : .imageLeft
            button.title = marker ?? ""
        } else {
            button.image = nil
            button.title = marker ?? "◧"
        }
    }

    func rebuildMenu(clientCount: Int = -1) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Hyperdisplay — Mac 虚拟扩展屏", action: nil, keyEquivalent: "")
        header.image = statusBarIcon
        header.image?.size = NSSize(width: 16, height: 16)
        menu.addItem(header)

        if !Permissions.hasScreenRecording() || restartForScreenRecordingPending {
            menu.addItem(.separator())
            if !Permissions.hasScreenRecording() {
                menu.addItem(withTitle: "⚠ 授权「屏幕录制」以显示副屏", action: nil, keyEquivalent: "")
            }
            if restartForScreenRecordingPending {
                menu.addItem(withTitle: "⚠ 屏幕录制已授权，需要重新启动 Host", action: nil, keyEquivalent: "")
            }
            let helperTitle = restartForScreenRecordingPending ? "显示重新启动提示…" : "显示授权拖拽引导…"
            let helper = menu.addItem(withTitle: helperTitle, action: #selector(showPermissionHelper), keyEquivalent: "")
            helper.target = self
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

        menu.addItem(withTitle: "屏幕数量与分辨率由平板保存的布局统一恢复", action: nil, keyEquivalent: "")

        menu.addItem(.separator())
        let loginItem = menu.addItem(withTitle: loginItemTitle(), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(withTitle: "配对码: \(pairingCode)（客户端首次连接需输入）", action: nil, keyEquivalent: "")
        let qrItem = menu.addItem(withTitle: "显示连接二维码…", action: #selector(showQR), keyEquivalent: "")
        qrItem.target = self
        let downloadAndroid = menu.addItem(withTitle: "下载 Android 客户端（GitHub Releases）…",
                                           action: #selector(openAndroidDownload), keyEquivalent: "")
        downloadAndroid.target = self
        menu.addItem(withTitle: "  下载 APK 后，平板按系统提示允许安装即可", action: nil, keyEquivalent: "")
        let port = udp?.port ?? config.port
        menu.addItem(withTitle: "本机 UDP \(port)：", action: nil, keyEquivalent: "")
        for line in Self.allInterfaceAddresses(port: Int(port)) {
            menu.addItem(withTitle: "  \(line)", action: nil, keyEquivalent: "")
        }
        if usbTunnel.adbAvailable {
            menu.addItem(withTitle: "USB 隧道 :\(UsbTunnelController.tcpPort)（\(usbTunnel.deviceCount) 台设备已配 reverse）", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "USB 隧道不可用（未找到 adb，装 platform-tools 或放 PATH）", action: nil, keyEquivalent: "")
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
        let resources = processResources.latest
        let hostMemoryMB = Double(resources.residentBytes) / 1_048_576
        menu.addItem(withTitle: String(format: "Host：CPU %.1f%% · 内存 %.0fMB（5 秒采样）",
                                       resources.cpuPercent, hostMemoryMB), action: nil, keyEquivalent: "")
        if clientCount >= 0 {
            menu.addItem(withTitle: "客户端: \(clientCount) 个在线", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出（全部虚拟屏自动销毁）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
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

    @objc private func openAndroidDownload() {
        NSWorkspace.shared.open(ReleaseLinks.androidDownload)
    }

    @objc private func requestScreenPerm() {
        permissionPanel.showScreenRecordingRequired(force: true)
    }

    @objc private func showPermissionHelper() {
        if !Permissions.hasScreenRecording() {
            permissionPanel.showScreenRecordingRequired(force: true)
        } else if restartForScreenRecordingPending {
            permissionPanel.showScreenRecordingRestartRequired(force: true)
        }
    }

    /// 正常退出会显式回收虚拟屏；短暂 helper 等退出完成后再启动新的 `.app` 实例。
    private func restartAfterScreenRecordingPermission() {
        guard restartForScreenRecordingPending else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "hyperdisplay-restart", Bundle.main.bundleURL.path]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("[hyperdisplay] could not schedule post-permission restart: \(error)")
        }
    }

    // MARK: 登录自启（零点击链路：Mac 侧常驻，AGENTS.md §7.1）

    private func refreshStatusIcon() {
        guard Permissions.hasScreenRecording() else {
            setStatusItemState("需要屏幕录制权限", marker: "!")
            return
        }
        switch displayHealth.level {
        case .hot: setStatusItemState("ColorSync 异常：请注销会话", marker: "!")
        case .warm: setStatusItemState("ColorSync 有残留", marker: "·")
        case .normal: setStatusItemState("Hyperdisplay（纯显示）")
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
        for deviceId in Set(streams.values.compactMap(\.deviceId)) {
            snapshotDevicePlacements(deviceId: deviceId)
        }
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
// UDP 不会触发 SIGPIPE；仍忽略它，避免未来非实时辅助 I/O 意外终止 host。
signal(SIGPIPE, SIG_IGN)

// 单实例锁：显示器创建虽已集中到 shim + createDisplay 护栏，但两个 host 进程并存
// 仍意味着双份建销 churn（2026-08-20 调试实测踩过）。文件锁拿不到 = 已有实例，直接退出。
let singleInstanceFd = open("/tmp/hyperdisplay.host.lock", O_CREAT | O_RDWR, 0o644)
// exec 重载前释放锁（档位切换路径）：锁随 fd 存续，CLOEXEC 保证 exec 后可重新获取
fcntl(singleInstanceFd, F_SETFD, FD_CLOEXEC)
if singleInstanceFd < 0 || flock(singleInstanceFd, LOCK_EX | LOCK_NB) != 0 {
    NSLog("[hyperdisplay] another host instance is running (lock held) — exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = HostApp(config: config)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
