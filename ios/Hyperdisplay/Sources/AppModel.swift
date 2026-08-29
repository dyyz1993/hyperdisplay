import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Network
import os.log

/// 会话编排（对照 MainActivity 的连接状态机，产品口径：纯显示、单屏优先）。
/// 阶段一范围：保存主机自动重连 / 手输 IP / mDNS 发现；分屏布局与 saved-layout
/// 恢复属阶段二。
/// 诊断：Console 过滤 subsystem = com.hyperdisplay.session。
@MainActor
final class AppModel: ObservableObject {

    private static let diag = Logger(subsystem: "com.hyperdisplay.session", category: "app")

    enum Phase { case connect, session }

    // MARK: Published UI 状态

    @Published var phase: Phase = .connect
    @Published var statusText = ""
    @Published var waitingText: String?          // nil = 不显示等待遮罩
    @Published var linkUp = false
    @Published var hasVideo = false
    @Published var activeDisplayId: UInt32?
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var showHostSheet = false

    // MARK: 布局状态（阶段二，对照 MainActivity 布局状态机）

    @Published var layoutConfig: LayoutConfig = LayoutConfig.load()
    @Published var subscribedIds: [UInt32] = []
    /// 布局替换过渡横幅；title==nil 表示隐藏
    @Published var bannerTitle: String?
    @Published var bannerDetail: String?
    /// 画中画窗口位置（设备像素域，与 wire 布局快照同单位；-1=未放置）
    @Published var pipLeft: Int = LayoutConfig.loadPipLeft()
    @Published var pipTop: Int = LayoutConfig.loadPipTop()
    @Published var pipSelected = false

    /// 仅在 Host 实测成功后才落盘的最后有效配置
    private(set) var committedLayoutConfig: LayoutConfig = LayoutConfig.load()
    private var pendingLayoutConfig: LayoutConfig?
    private var pendingModeTransaction: UInt32 = 0
    private var nextModeTransaction: UInt32 = 1
    /// 布局替换必须等整组新屏都至少渲染一帧才能收横幅
    private var topologyTransitionInFlight = false
    private var topologyExpectedIds: Set<UInt32> = []
    private var topologyBannerSinceMs = UInt64(0)
    /// 防止旧屏尚未销毁时每枚 DISPLAYS 都重复发起规格校正
    private var profileSyncRequested: [SizeSpec]?
    /// 主屏等待第二块屏的过渡占位（对照 pendingSecondScreen）
    @Published var awaitingSecondDisplay = false
    /// 连接页诊断行：本机 IP + 发现通道状态（发给用户排查用）
    @Published var diagText = ""
    /// 发现失败 12 秒后出现「直连测试」按钮
    @Published var showDirectTest = false
    private var directTestTimer: Timer?

    /// 连接页输入框（UserDefaults 同步）
    @Published var endpointText: String = UserDefaults.standard.string(forKey: "hd.host") ?? ""
    @Published var pairingCodeText: String = {
        let code = UserDefaults.standard.integer(forKey: "hd.pairingCode")
        return code > 0 ? String(code) : ""
    }()
    @AppStorage("hd.showStats") var showStats = true // 调试期默认开：光标/尺寸问题需要真实数字
    @Published var statsLine = ""
    /// 传输徽标文案：跟随 NWPathMonitor 的真实出口接口（Wi-Fi/有线/蜂窝）。
    /// 徽标只代表 UDP 链路已建立；接口名才回答"流量走的是什么网"——
    /// 手机当热点、Wi-Fi 图标误判等场景下，硬编码 "Wi-Fi" 会误导排查。
    @Published private(set) var transportLabel = "…"
    private let pathMonitor = NWPathMonitor()
    /// 光标包到达速率（诊断光标卡顿：网络抖动 vs 渲染问题）
    private var cursorPacketCount = 0
    private var cursorRate = 0

    // MARK: 内部状态

    private var session: HostSession?
    /// 当前会话目标 host（USB 升级判断用：已在 USB 上就不重复切）
    private var sessionHost: String?
    /// USB 热点链路监视（对照安卓 §7.2：插线自动升级、拔线自动降级 WiFi，零输入）
    private let usbWatcher = UsbLinkWatcher()
    /// 管线注册表：视频分片在视频线程按 displayId 直查（AppModel 是 @MainActor，
    /// 普通字典跨线程裸访问是数据竞争）
    private final class PipelineRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [UInt32: VideoPipeline] = [:]
        func pipeline(_ id: UInt32) -> VideoPipeline? {
            lock.lock(); defer { lock.unlock() }
            return map[id]
        }
        func upsert(_ p: VideoPipeline) {
            lock.lock(); defer { lock.unlock() }
            map[p.displayId] = p
        }
        var all: [VideoPipeline] {
            lock.lock(); defer { lock.unlock() }
            return Array(map.values)
        }
        /// 只保留 ids，返回被移除的管线（调用方负责 teardown）
        func keepOnly(_ ids: Set<UInt32>) -> [VideoPipeline] {
            lock.lock(); defer { lock.unlock() }
            let removed = map.values.filter { !ids.contains($0.displayId) }
            map = map.filter { ids.contains($0.key) }
            return removed
        }
        func removeAll() -> [VideoPipeline] {
            lock.lock(); defer { lock.unlock() }
            let removed = Array(map.values)
            map.removeAll()
            return removed
        }
    }
    private let registry = PipelineRegistry()
    private let browser = DiscoveryBrowser()
    private var stallTimer: Timer?
    /// 后台被迫断开过 → 回前台无缝重连（host 侧 EDID 档案还原）
    private var reconnectOnForeground = false
    private var lastStatTickAtMs = UInt64(0)
    private var lastRenderedSnapshot: [UInt32: Int] = [:]
    // 视图挂接：光标全局唯一（对照安卓 root 级 LocalCursorView 单例，杜绝区域
    // 重建产生双光标实例）；视频视图按 displayId 注册（光标坐标换算源）
    var cursorOverlayRef: WeakRef<CursorOverlayView>?
    private var videoViewRefs: [(UInt32, WeakRef<VideoLayerView>)] = []

    private func videoView(for displayId: UInt32) -> VideoLayerView? {
        videoViewRefs = videoViewRefs.filter { $0.1.value != nil }
        return videoViewRefs.first(where: { $0.0 == displayId })?.1.value
            ?? videoViewRefs.first?.1.value
    }

    init() {
        browser.onUpdate = { [weak self] hosts in
            guard let self else { return }
            self.discoveredHosts = hosts.sorted { $0.name < $1.name }
            guard self.phase == .connect, !self.showHostSheet else { return }
            // §7.4 多主机智能选择：发现恰好 1 台直接连，>1 台才弹列表
            if hosts.count == 1 {
                let host = hosts[0]
                if host.pairingCode == 0,
                   UserDefaults.standard.integer(forKey: "hd.pairingCode") == 0 {
                    // 单播扫描发现、且本机没有配对码：只能填地址，配对码需用户补一次
                    self.endpointText = "\(host.host):\(host.port)"
                    self.statusText = "已发现 Mac（\(host.host)）：请填写配对码后点连接"
                } else {
                    self.connectEntry(host)
                }
            } else if hosts.count > 1 {
                self.showHostSheet = true
            }
        }
        browser.onError = { [weak self] message in
            self?.statusText = message
            self?.stopDiscovery()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let label: String
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) { label = "Wi-Fi" }
                else if path.usesInterfaceType(.wiredEthernet) { label = "有线" }
                else if path.usesInterfaceType(.cellular) { label = "蜂窝" }
                else { label = "网络" }
            case .unsatisfied, .requiresConnection:
                label = "无网络"
            @unknown default:
                label = "网络"
            }
            Task { @MainActor [weak self] in self?.transportLabel = label }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hyperdisplay-path-monitor"))
        usbWatcher.onUsbHostFound = { [weak self] ip in
            DispatchQueue.main.async { self?.upgradeToUsbLink(host: ip) }
        }
        usbWatcher.onUsbLinkLost = { [weak self] in
            DispatchQueue.main.async { self?.downgradeFromUsbLink() }
        }
    }

    /// USB 热点链路出现且探到 host：热切换会话（stopQuietly 语义，host 侧
    /// EDID 身份恒定保留屏幕）。不动 UserDefaults——保存的仍是 WiFi 地址，
    /// 拔线降级时直接回归。插线即生效，用户零输入（§7 零点击基线）。
    private func upgradeToUsbLink(host: String) {
        guard phase == .session || phase == .connect else { return }
        guard sessionHost != host else { return }
        Self.diag.log("USB link up (\(host, privacy: .public)) — switching session")
        sessionHost = host
        openSession(host: host, port: 5277)
    }

    /// USB 拔线：当前会话若在 USB 上，回落到保存的 WiFi 地址重连
    private func downgradeFromUsbLink() {
        guard phase == .session, let host = sessionHost,
              host.hasPrefix("172.20.10.") else { return }
        Self.diag.log("USB link lost — falling back to Wi-Fi")
        sessionHost = nil
        session?.stopQuietly()
        smartConnect()
    }

    deinit {
        session = nil // goodbye 走显式路径；deinit 只保证连接取消
        stallTimer?.invalidate()
        browser.stop()
        pathMonitor.cancel()
    }

    // MARK: - 连接入口

    func bootstrap() {
        UIApplication.shared.isIdleTimerDisabled = true
        usbWatcher.start() // 插线自动升级 USB / 拔线自动降级，全程后台
        smartConnect()
    }

    /// 智能连接：先复用已保存地址，否则自动发现局域网内的 Mac。
    /// iOS 无 adb 隧道可探测，跳过安卓端的有线优先分支。
    func smartConnect() {
        statusText = ""
        stopDiscovery()
        if let (ip, port) = parseEndpoint(endpointText) {
            openSession(host: ip, port: port)
        } else {
            startDiscovery()
        }
    }

    func connectFromForm() {
        let text = endpointText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            smartConnect()
            return
        }
        guard let (ip, port) = parseEndpoint(text) else {
            statusText = "地址格式不对，应形如 192.168.1.23:5277"
            return
        }
        UserDefaults.standard.set(text, forKey: "hd.host")
        savePairingCode()
        openSession(host: ip, port: port)
    }

    /// 发现结果直接连接：主机地址 + TXT 配对码一并记住（零点击）
    func connectEntry(_ entry: DiscoveredHost) {
        UserDefaults.standard.set("\(entry.host):\(entry.port)", forKey: "hd.host")
        if entry.pairingCode != 0 {
            UserDefaults.standard.set(Int(entry.pairingCode), forKey: "hd.pairingCode")
            pairingCodeText = String(entry.pairingCode)
        }
        endpointText = "\(entry.host):\(entry.port)"
        stopDiscovery()
        openSession(host: entry.host, port: entry.port)
    }

    func manualStartDiscovery() {
        smartConnect()
    }

    func cancelToConnectScreen() {
        disconnect(removeDisplay: true)
    }

    // MARK: - 会话生命周期

    private func openSession(host: String, port: UInt16) {
        disconnect(removeDisplay: false) // 幂等重建
        sessionHost = host
        guard let s = HostSession(host: host, port: port, listener: self,
                                  code: UInt32(clamping: Int(UserDefaults.standard.integer(forKey: "hd.pairingCode"))),
                                  deviceId: DeviceIdentity.loadOrCreateDeviceId(),
                                  fingerprint: DeviceIdentity.loadDeviceFingerprint(),
                                  deviceName: DeviceIdentity.deviceDisplayName(),
                                  clientWidth: Self.clientWidth(), clientHeight: Self.clientHeight(),
                                  specs: requestedDisplaySpecs(), layout: currentWireLayout()) else {
            phase = .connect
            statusText = "无法解析地址（仅支持数字 IPv4）"
            return
        }
        session = s
        phase = .session
        linkUp = false
        hasVideo = false
        activeDisplayId = nil
        profileSyncRequested = nil
        bannerTitle = nil
        bannerDetail = nil
        lastSentPixels = Self.videoRegionPixels()
        waitingText = "等待 Mac 主机…"
        statusText = ""
        s.start()
        startStallTimer()
    }

    /** removeDisplay=true 才发 BYE 并让 host 移除虚拟屏；换路由重连不得发，
     *  否则会拆掉当前 Host 正在恢复的同设备屏幕。 */
    func disconnect(removeDisplay: Bool) {
        stopStallTimer()
        stopDiscovery()
        registry.removeAll().forEach { $0.teardown() }
        subscribedIds = []
        activeDisplayId = nil
        hasVideo = false
        linkUp = false
        waitingText = nil
        bannerTitle = nil
        bannerDetail = nil
        topologyTransitionInFlight = false
        topologyExpectedIds = []
        pipSelected = false
        statsLine = ""
        guard let s = session else {
            phase = .connect
            return
        }
        session = nil
        phase = .connect
        if removeDisplay {
            s.goodbyeAndStop()
        } else {
            s.stopQuietly()
        }
    }

    /// 场景生命周期：iOS app 退后台几秒内会被挂起，socket 直接死亡——
    /// 与其等系统杀不如立刻发 BYE 让 host 及时回收；回前台靠 EDID 档案零点击还原。
    func handleScenePhase(_ scene: ScenePhase) {
        switch scene {
        case .background:
            if phase == .session {
                reconnectOnForeground = true
                disconnect(removeDisplay: true)
            }
        case .active:
            if reconnectOnForeground {
                reconnectOnForeground = false
                Self.diag.log("resumed after background disconnect — reconnecting")
                smartConnect()
            }
        default:
            break
        }
    }

    // MARK: - 发现

    private func startDiscovery() {
        statusText = "正在搜索局域网内的 Mac…"
        browser.start()
        // mDNS 与单播扫描并行：mDNS 依赖路由器在设备间转发组播（常被丢弃），
        // 单播扫描不受限。两边谁先发现都算数（按 host id 去重）。
        browser.startSweepFallback()
        // MPC 近场发现（AWDL/直连，不经路由器）：AP 隔离网络里的最后手段。
        // host 通过 MPC 会话直接报 UDP 端点+配对码。
        MPCBrowser.shared.onHost = { [weak self] host in
            guard let self, self.phase == .connect else { return }
            Self.diag.log("MPC discovered host \(host.host):\(host.port)")
            if UserDefaults.standard.integer(forKey: "hd.pairingCode") > 0 || host.pairingCode != 0 {
                self.connectEntry(host)
            } else {
                self.endpointText = "\(host.host):\(host.port)"
                self.statusText = "已发现 Mac（\(host.host)）：请填写配对码后点连接"
            }
        }
        MPCBrowser.shared.start()
        // 诊断：本机 IP 直接决定扫描网段；169.254 = Wi-Fi 没真正接入局域网
        if let (prefix, ip) = DiscoveryBrowser.localLANIPv4() {
            diagText = "诊断：本机 \(ip)（扫描 \(prefix)x）· mDNS/扫描/MPC 三通道进行中"
        } else if DiscoveryBrowser.hasOnlyLinkLocal() {
            diagText = "诊断：本机只有 169.254 自分配地址 —— Wi-Fi 未接入局域网，请到设置连接路由器 Wi-Fi"
        } else {
            diagText = "诊断：本机没有 IPv4 —— 手机可能没连 Wi-Fi（在用蜂窝数据？）"
        }
        directTestTimer?.invalidate()
        showDirectTest = false
        let t = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showDirectTest = true }
        }
        RunLoop.main.add(t, forMode: .common)
        directTestTimer = t
    }

    private func stopDiscovery() {
        browser.stop()
        MPCBrowser.shared.stop()
        discoveredHosts = []
        directTestTimer?.invalidate()
        showDirectTest = false
    }

    /// 紧凑高清实验：显示长边切 2240 档（清晰度↑，桌面逻辑更大）
    func setCompactTier() {
        layoutConfig.displayLongEdge = 2240
        layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
    }

    // MARK: - 周期任务（停滞检测 + 统计）

    private func startStallTimer() {
        stopStallTimer()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stallTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        stallTimer = t
    }

    private func stopStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
        lastRenderedSnapshot.removeAll()
    }

    private func stallTick() {
        for p in registry.all { p.heartbeat() }
        // 布局替换横幅：整组新屏都出过一帧才能收（旧屏仍在播放时不能提前撤）；
        // 但 host 只建出部分屏（或建屏失败）时不能永远挂着——12s 强制收起。
        if topologyTransitionInFlight {
            if !topologyExpectedIds.isEmpty,
               topologyExpectedIds.allSatisfy({ (registry.pipeline($0)?.framesRendered ?? 0) > 0 }) {
                topologyTransitionInFlight = false
                topologyExpectedIds = []
                bannerTitle = nil
                bannerDetail = nil
            } else if FrameAssembler.nowMs() &- topologyBannerSinceMs > 12_000 {
                Self.diag.log("topology banner timeout — host may have built only part of the screens")
                topologyTransitionInFlight = false
                topologyExpectedIds = []
                bannerTitle = nil
                bannerDetail = nil
            }
        }
        updateStats()
    }

    // MARK: 旋转重建（安卓 M5 未做的「旋转重建」，iOS 借会话内换拓扑补齐）

    private var lastSentPixels: ScreenPixels?
    private var rotationDebounceTask: Task<Void, Never>?

    /// 容器尺寸变化（旋转/分屏形态变化）→ 防抖后按新方向受控重建虚拟屏。
    /// 同一次旋转会触发一串 geometry 变化，只有最终稳定方向真正发出 HELLO。
    func handleViewportChange() {
        guard phase == .session, session != nil, linkUp else { return }
        let pixels = Self.videoRegionPixels()
        guard pixels != lastSentPixels else { return }
        rotationDebounceTask?.cancel()
        rotationDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let stable = Self.videoRegionPixels()
            guard stable == pixels, stable != self.lastSentPixels,
                  self.phase == .session, self.session != nil else { return }
            self.lastSentPixels = stable
            Self.diag.log("viewport changed -> \(stable.width)x\(stable.height), rebuilding topology")
            self.bannerTitle = "正在按新方向重建屏幕…"
            self.bannerDetail = "旋转已识别，画面马上回来"
            self.beginTopologyTransition()
            self.session?.updateDisplayTopology(specs: self.requestedDisplaySpecs(),
                                                layout: self.currentWireLayout())
        }
    }

    private func updateStats() {
        guard showStats else { return }
        let now = FrameAssembler.nowMs()
        guard now &- lastStatTickAtMs >= 1000 else { return }
        lastStatTickAtMs = now
        cursorRate = cursorPacketCount
        cursorPacketCount = 0
        var parts: [String] = []
        parts.append(linkUp ? "链路OK" : "断")
        parts.append("标\(cursorRate)/s")
        for p in registry.all.sorted(by: { $0.displayId < $1.displayId }) {
            let previous = lastRenderedSnapshot[p.displayId] ?? p.framesRendered
            let fps = p.framesRendered &- previous
            lastRenderedSnapshot[p.displayId] = p.framesRendered
            parts.append("屏\(p.displayId) \(p.width)x\(p.height) ~\(fps)fps")
        }
        // 弃帧原因（3s 内有效）：真机诊断靠用户念这一行——gap=帧号缺口（网络丢帧）、
        // stall=分片停滞、decoder queue full=解码背压、keyframe missing=IDR 缺片被弃
        if let reason = lastKeyframeReason,
           FrameAssembler.nowMs() &- lastKeyframeReasonAtMs < 3_000 {
            parts.append("因:\(reason)")
        }
        statsLine = parts.joined(separator: "  ")
    }

    // MARK: - 工具

    /// 关键帧请求限频：同屏 2s 内只发一次。host 的静止锐化会周期性自发 IDR，
    /// 客户端密集请求只会放大突发（真机实测 2s 一个巨型 IDR 挤爆 WiFi，
    /// 光标包被挤到卡成幻灯片）。
    private var lastKeyframeRequestAt: [UInt32: UInt64] = [:]

    func pipelineOf(id: UInt32) -> VideoPipeline {
        if let existing = registry.pipeline(id) { return existing }
        let p = VideoPipeline(displayId: id, callbacks: .init(
            // 回调可能在视频线程触发（已限频 ≤2/s）：回主线程统一处理，实现保持 MainActor 直觉
            requestKeyframe: { [weak self] displayId, reason in
                DispatchQueue.main.async { self?.requestKeyframeMain(displayId, reason: reason) }
            },
            sendNack: { [weak self] displayId, frameId, missing in
                DispatchQueue.main.async {
                    self?.session?.sendNack(displayId: UInt16(clamping: Int(displayId)),
                                            frameId: frameId, indices: missing)
                }
            },
            firstFrameRendered: { [weak self] in
                self?.hasVideo = true
                self?.waitingText = nil
            }
        ))
        registry.upsert(p)
        return p
    }

    /// requestKeyframe 闭包的主线程落点（同屏 2s 限频）。reason 记入状态行供真机诊断。
    private func requestKeyframeMain(_ displayId: UInt32, reason: String) {
        let now = FrameAssembler.nowMs()
        lastKeyframeReason = reason
        lastKeyframeReasonAtMs = now
        if let last = lastKeyframeRequestAt[displayId], now &- last < 2_000 { return }
        lastKeyframeRequestAt[displayId] = now
        session?.requestKeyframe(displayId: UInt16(clamping: Int(displayId)))
    }

    /// 最近一次弃帧原因（3s 内才显示——状态行是给用户念给开发者听的诊断仪表）
    private var lastKeyframeReason: String?
    private var lastKeyframeReasonAtMs: UInt64 = 0

    func pipeline(for id: UInt32) -> VideoPipeline? { registry.pipeline(id) }

    /// 区域序号 → displayId（越界 = 第二块屏还没建立）
    func regionId(at index: Int) -> UInt32? {
        guard index < subscribedIds.count else { return nil }
        return subscribedIds[index]
    }

    /// PiP 拖动/缩放落点持久化
    func persistPipPosition() {
        layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
    }

    static func clientWidth() -> UInt16 {
        UInt16(clamping: max(320, Int(screenPixels().width)))
    }

    static func clientHeight() -> UInt16 {
        UInt16(clamping: max(240, Int(screenPixels().height)))
    }

    /// 当前方向的完整物理像素（不做横屏归一）。旋转后由 handleViewportChange
    /// 走受控重建：虚拟屏跟随 iPad 的真实方向，而不是固定横屏留黑边。
    static func screenPixels() -> ScreenPixels {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen ?? UIScreen.main
        let bounds = screen.bounds.size
        let scale = screen.scale
        return ScreenPixels(width: Int(bounds.width * scale), height: Int(bounds.height * scale))
    }

    /// 屏幕缩放系数（像素/点），PiP 像素域坐标 ↔ UI 点坐标换算用
    static func screenScale() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.screen ?? UIScreen.main).scale
    }

    /// 顶部刘海行预留 = 系统真实安全区顶（刘海/灵动岛高度，iPhone13≈47pt）。
    /// UI 与请求规格共用同一来源，保证宽高比严格一致（此前固定 24pt 与
    /// 安全区叠加，双重预留让实际区域变"矮胖"→ aspect-fit 左右留黑边）。
    static var videoTopInsetPt: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return max(24, scene?.keyWindow?.safeAreaInsets.top ?? 24)
    }

    /// 紧凑显示档：虚拟屏长边抬到 2240（DisplayResolution 档位 4），逻辑桌面
    /// 变大 → 同尺寸屏上字体更细腻。为清晰度调试加的请求端开关，默认关。
    static func requestedDisplaySpecs(config: LayoutConfig, compact: Bool) -> [RequestedDisplaySpec] {
        var cfg = config
        if compact { cfg.displayLongEdge = 2240 }
        let px = Self.videoRegionPixels()
        return LayoutGeometry.requestedSpecs(config: cfg, screenW: px.width, screenH: px.height)
    }

    /// 视频可视区的完整物理像素：全宽 ×（全高 − 刘海行）。
    /// 虚拟屏按这个比例建 → aspect-fit 恰好铺满可视区，四周零黑边。
    /// 宽高向下取整到 16 的倍数：host 建 CGVirtualDisplay 前按 16px 对齐，
    /// 请求值先对齐可消除对齐取整带来的比例漂移（漂移=可见黑边）。
    static func videoRegionPixels() -> ScreenPixels {
        // 可视区（全宽 × 全高−刘海行），但发请求前先在「16 的倍数」约束下搜索
        // 比例最接近可视区的组合——host makeProfiles 会对 spec 做 (v+15)&~15
        // 向上对齐，两端独立取整会让宽高比漂移 1%（iPhone 实测 = 肉眼可见的
        // 左右黑边）。搜索让请求值=host 最终建屏值且比例误差最小（<0.1%）。
        let px = screenPixels()
        let inset = Int(videoTopInsetPt * screenScale())
        let rawW = max(640, px.width)
        let rawH = max(480, px.height - inset)
        let target = Double(rawW) / Double(rawH)
        func floor16(_ v: Int) -> Int { max(640, v & ~15) }
        func ceil16(_ v: Int) -> Int { max(640, (v + 15) & ~15) }
        func round16(_ v: Double) -> Int { max(480, (Int(v.rounded()) + 8) & ~15) }
        // 宽度至少 1280：host 的 2x 几何要求物理像素 ≥1280x960，否则只能建 1x
        // 巨画布（手机上 UI 缩成 1/3、且高像素推高码率需求）。宽度达标即得 2x：
        // 逻辑减半（UI 正常大小）、像素高清。iPhone13: 1280x2688 → 逻辑 640x1344。
        let wFloor = floor16(rawW)
        let wCeil = ceil16(rawW)
        var best = (w: wCeil, h: round16(Double(wCeil) / target))
        var bestErr = Double.greatestFiniteMagnitude
        for w in [wFloor, wCeil] {
            let h = round16(Double(w) / target)
            let err = abs(Double(w) / Double(h) - target)
            if err < bestErr {
                bestErr = err
                best = (w, h)
            }
        }
        return ScreenPixels(width: best.w, height: best.h)
    }

    private func parseEndpoint(_ text: String) -> (String, UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = HostSession.parseIPv4(String(parts[0])) else { return nil }
        if parts.count > 1 {
            guard let port = UInt16(parts[1]), port > 0 else { return nil }
            return (host, port)
        }
        return (host, DiscoveryBrowser.defaultPort)
    }

    private func savePairingCode() {
        if let code = UInt32(pairingCodeText.trimmingCharacters(in: .whitespaces)) {
            UserDefaults.standard.set(Int(code), forKey: "hd.pairingCode")
        }
    }
}

// MARK: - HostSessionListener

/// 洪水盾状态（文件级，nonisolated：会话回调线程读写，NSLock 保护）
private let shieldLock = NSLock()
private var shieldLastKey = ""
private var shieldLastAtMs = UInt64(0)

extension AppModel: HostSessionListener {

    /// 洪水盾：host 拓扑异常时会对同一 WELCOME/DISPLAYS 状态 kHz 级重推
    /// （伴随 host CPU 134%），每包 Task 跳主线程会把主 actor 饿死 → UI 冻结
    /// （真机实测）。重复包在会话回调线程就地丢弃，同键 500ms 窗口内只放行一次。
    nonisolated private static func shieldDrop(_ packet: HostPacket, now: UInt64) -> Bool {
        let key: String
        switch packet {
        case .welcome(let d, _, let c, let w, let h, let fps, _):
            key = "w|\(d)|\(c)|\(w)|\(h)|\(fps)"
        case .displays(let list):
            key = "d|\(list.map { "\($0.id):\($0.width)x\($0.height)" }.joined(separator: ","))"
        default:
            return false
        }
        shieldLock.lock()
        defer { shieldLock.unlock() }
        if key == shieldLastKey, now &- shieldLastAtMs < 500 {
            return true
        }
        shieldLastKey = key
        shieldLastAtMs = now
        return false
    }

    nonisolated func hostSession(_ session: HostSession, didReceive packet: HostPacket) {
        if Self.shieldDrop(packet, now: FrameAssembler.nowMs()) { return }
        // HostSession 只经 notifyOnMain（主线程）调本方法；assumeIsolated 消掉旧实现
        // 每包新建 Task{@MainActor} 的第二跳调度（高频控制包下是可感知的延迟与分配）
        MainActor.assumeIsolated { self.handle(packet: packet) }
    }

    nonisolated func hostSession(_ session: HostSession,
                                 didReceiveVideoFragment displayId: UInt32,
                                 frameId: Int64, fragIdx: Int, fragCount: Int,
                                 keyframe: Bool, payload: Data) {
        // sessionQueue 上下文：锁内查表后直达管线串行队列，全程不碰主线程
        guard let pipeline = registry.pipeline(displayId) else { return }
        pipeline.handleFragment(frameId: frameId, fragIdx: fragIdx, fragCount: fragCount,
                                keyframe: keyframe, payload: payload)
    }

    nonisolated func hostSession(_ session: HostSession,
                                 didReceiveCursor displayId: UInt32, x: Float, y: Float) {
        // 已由 HostSession 单跳到主线程；直接更新 overlay，不再二次调度
        MainActor.assumeIsolated {
            cursorPacketCount += 1
            guard let overlay = cursorOverlayRef?.value else { return }
            if displayId == 0 {
                overlay.hide()
                return
            }
            // 流坐标 → 目标视频视图内容区坐标 → 全局光标视图坐标（对照安卓
            // streamToView + windowPos 双窗口原点换算）。displayId 未命中时回落
            // 首个视频视图（host 拓扑回退换 id 时光标不至于消失）；换算越界 =
            // 整包丢弃，光标停在原地（安卓同语义）。
            guard let videoView = videoView(for: displayId),
                  let local = videoView.contentPoint(forStreamX: CGFloat(x), y: CGFloat(y)) else { return }
            let p = videoView.convert(local, to: overlay)
            overlay.moveTo(viewX: p.x, viewY: p.y)
        }
    }

    nonisolated func hostSession(_ session: HostSession, linkChangedUp up: Bool) {
        Task { @MainActor in self.handleLink(up: up) }
    }

    nonisolated func hostSessionNeedsRediscovery(_ session: HostSession) {
        Task { @MainActor in self.handleStaleHost() }
    }

    private func handle(packet: HostPacket) {
        switch packet {
        case .welcome(let displayId, _, let codec, let w, let h, let fps, _):
            // 纯显示模式：无视 controlEnabled，绝不发送输入报文
            Self.diag.log("WELCOME display=\(displayId) codec=\(codec) \(w)x\(h) fps=\(fps)")
            let pipeline = pipelineOf(id: UInt32(displayId))
            pipeline.handleWelcome(codec: codec, width: Int(w), height: Int(h), fps: Int(fps))
            // 流尺寸是光标坐标换算的基准：WELCOME 到达时同步给光标层，
            // 否则尺寸为 0 → streamToView 恒 nil → 光标永远不显示
            let surface = videoView(for: UInt32(displayId))
            surface?.setStreamSize(w: Int(w), h: Int(h))

        case .config(let displayId, _, let paramSets):
            Self.diag.log("CONFIG display=\(displayId) csd=\(paramSets.count) bytes")
            pipelineOf(id: UInt32(displayId)).handleConfig(paramSets)

        case .displays(let list):
            handleDisplays(list)

        case .cursorBitmap(let image):
            // 系统光标位图是全局一份（安卓同语义），全局光标视图直接更新
            cursorOverlayRef?.value?.setSystemCursorBitmap(width: image.width, height: image.height,
                                                           hotX: image.hotX, hotY: image.hotY,
                                                           bgra: image.pixels)

        case .savedLayout(let wire):
            handleSavedLayout(wire)

        case .displayModeStatus(let transaction, let status, _, let requestedScale, let actualScale):
            handleDisplayModeStatus(transaction: transaction, status: status,
                                    requestedScale: requestedScale, actualScale: actualScale)

        case .cursorImage, .inputAck, .pong, .cursor, .videoFragment:
            break // 光标分片由 HostSession 组装；pong 状态机在会话层内部；
                  // cursor/videoFragment 走专用高频通道（HostSession 就地分流），不该到这
        }
    }

    /// 多屏订阅（对照 MainActivity.onDisplays）：按当前布局需要的屏数取前 n 块，
    /// 订阅集不变时绝不重复 selectDisplay/requestKeyframe——host 会为每次订阅变更
    /// 重推 DISPLAYS+WELCOME，无条件的重订阅会形成 kHz 级正反馈风暴。
    private func handleDisplays(_ list: [DisplayInfo]) {
        guard !list.isEmpty else {
            // Host 在跑但没有任何屏：明确提示"Mac 服务未启动/未建屏"，
            // 不给"等待/正在建立"的模糊态（用户无法区分服务没开还是正在建）
            waitingText = "Mac 服务未启动 —— 请在 Mac 菜单栏打开 Hyperdisplay"
            statusText = "Mac 在线但未创建虚拟屏"
            return
        }
        let wanted = max(LayoutGeometry.requestedSpecs(config: layoutConfig,
                                                       screenW: Self.screenPixels().width,
                                                       screenH: Self.screenPixels().height).count, 1)
        let selected = list.prefix(wanted)
        let desiredIds = selected.map(\.id)
        awaitingSecondDisplay = desiredIds.count < wanted
        // 第二屏占位视图自己会说明"正在建立"，等待遮罩别再叠一层文字（会重叠成乱码）
        if awaitingSecondDisplay { waitingText = nil }

        if subscribedIds.isEmpty {
            subscribedIds = desiredIds
            resetPipelines(keep: [])
            beginTopologyArming(expectedIds: Set(desiredIds))
            desiredIds.forEach { requestKeyframeMain($0, reason: "subscription changed") }
        } else if desiredIds != subscribedIds {
            let oldIds = subscribedIds
            subscribedIds = desiredIds
            if layoutConfig.kind == .pip, oldIds.count == 1, desiredIds.count == 2,
               oldIds.first == desiredIds.first {
                // 画中画增量：只给后到的第二块建管线，主画面不重建避免再次闪黑
                beginTopologyArming(expectedIds: Set(desiredIds))
            } else {
                resetPipelines(keep: [])
                beginTopologyArming(expectedIds: Set(desiredIds))
            }
            desiredIds.forEach { requestKeyframeMain($0, reason: "subscription changed") }
        } else {
            awaitingSecondDisplay = false
        }

        activeDisplayId = subscribedIds.first
        if subscribedIds.count == 1 {
            session?.selectDisplay(id: subscribedIds[0])
        } else if !subscribedIds.isEmpty {
            session?.subscribeDisplays(ids: subscribedIds)
        }
        // 关键帧请求只随订阅集变更发出（对照安卓：仅首建/变更分支发）。host 重推
        // DISPLAYS 时旧实现每包都请求，等于给 host 的 IDR/码率系统持续添堵。
        if !hasVideo { waitingText = waitingText ?? "等待画面…" }
        reconcileCurrentDeviceDisplayProfile(list)
    }

    /// 卸载重装恢复（对照 restoreLayoutFromHost）：应用 host 保存的布局 → ACK →
    /// 稍后把本机真实画布提交为新权威。250ms 延迟只保证 ACK 先到达。
    private func handleSavedLayout(_ wire: LayoutWire) {
        layoutConfig = LayoutGeometry.config(fromWire: wire)
        pipLeft = Int(wire.pipLeft)
        pipTop = Int(wire.pipTop)
        layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
        committedLayoutConfig = layoutConfig
        pendingLayoutConfig = nil
        session?.acknowledgeSavedLayout()
        // Host 只在 ACK 前保护旧档案；确认后再提交本机真实画布，旧安装遗留的
        // 规格不会在重装恢复后永久造成等比黑边。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let session = self.session else { return }
            session.updateDisplayTopology(specs: self.requestedDisplaySpecs(),
                                          layout: self.currentWireLayout())
        }
    }

    /// 显示模式状态机（对照 onDisplayModeStatus）：旧事务的 UDP 重传不能覆盖新意图
    private func handleDisplayModeStatus(transaction: UInt32, status: DisplayModeStatus,
                                         requestedScale: UInt8, actualScale: UInt8) {
        guard transaction != 0, transaction == pendingModeTransaction else { return }
        switch status {
        case .validating:
            bannerTitle = "正在验证 Retina…"
            bannerDetail = "正在确认 Mac 是否真正提供 2x"
        case .ready:
            if requestedScale == 2 && actualScale != 2 { return } // 旧事务重传，勿覆盖
            pendingLayoutConfig = nil
            pendingModeTransaction = 0
            committedLayoutConfig = layoutConfig
            layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
            bannerDetail = "实测 \(actualScale)x，正在恢复画面…"
        case .unsupported, .failed:
            let restore = committedLayoutConfig
            layoutConfig = restore
            pendingLayoutConfig = nil
            pendingModeTransaction = 0
            layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
            bannerTitle = status == .unsupported ? "当前组合不支持 Retina" : "切换未完成"
            bannerDetail = "已恢复上一套有效显示配置"
            beginTopologyTransition()
            session?.updateDisplayTopology(specs: requestedDisplaySpecs(config: restore),
                                           layout: currentWireLayout(config: restore))
        }
    }

    /// 布局应用引擎（对照 applyLayout）：虚拟屏尺寸变化走受控事务（旧画面保留到
    /// 新屏首帧），纯本地参数变化直接提交不断流。
    func applyLayout(_ cfg: LayoutConfig) {
        let previous = layoutConfig
        let changed = previous != cfg
        let virtualScreenChange = previous.kind != cfg.kind ||
            previous.clarity != cfg.clarity ||
            requestedDisplaySpecs(config: previous) != requestedDisplaySpecs(config: cfg)
        layoutConfig = cfg
        guard changed else { return }
        guard session != nil else {
            // 离线只保存用户已明确选择的布局；下次连接仍会对 Retina 做严格验证
            layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
            committedLayoutConfig = cfg
            return
        }
        if virtualScreenChange {
            pendingLayoutConfig = cfg
            pendingModeTransaction = nextModeTransaction
            nextModeTransaction &+= 1
            beginTopologyTransition()
            session?.updateDisplayTopology(specs: requestedDisplaySpecs(config: cfg),
                                           layout: currentWireLayout(config: cfg,
                                                                     transaction: pendingModeTransaction))
        } else {
            layoutConfig.save(pipLeft: pipLeft, pipTop: pipTop)
            committedLayoutConfig = cfg
            session?.updateDisplayTopology(specs: requestedDisplaySpecs(config: cfg),
                                           layout: currentWireLayout(config: cfg))
        }
    }

    private func beginTopologyTransition() {
        topologyTransitionInFlight = true
        topologyBannerSinceMs = FrameAssembler.nowMs()
        bannerTitle = "正在应用新的屏幕布局"
        bannerDetail = "保留当前画面，正在优化副屏…"
    }

    private func beginTopologyArming(expectedIds: Set<UInt32>) {
        topologyExpectedIds = expectedIds
        if !topologyTransitionInFlight {
            bannerTitle = nil
            bannerDetail = nil
        }
    }

    private func resetPipelines(keep: Set<UInt32>) {
        registry.keepOnly(keep).forEach { $0.teardown() }
    }

    // MARK: 布局换算

    func requestedDisplaySpecs() -> [RequestedDisplaySpec] {
        requestedDisplaySpecs(config: layoutConfig)
    }

    func requestedDisplaySpecs(config: LayoutConfig) -> [RequestedDisplaySpec] {
        // 关键：按「可视区」（全宽 × 全高−刘海行）请求虚拟屏比例，
        // 而不是整机屏幕——否则顶部留条后 aspect-fit 必然左右出黑边
        let px = Self.videoRegionPixels()
        return LayoutGeometry.requestedSpecs(config: config, screenW: px.width, screenH: px.height)
        // 注：曾试验「请求双倍像素」抵消 host 的减半降级（画面更清晰），但 host
        // 尺寸管道对超规请求的落点不可预测（实测落 1024x1474），且与规格校正
        // 打架形成推送风暴——已回退。清晰度根因待 host 侧降级路径修复。
    }

    func currentWireLayout(transaction: UInt32 = 0) -> LayoutWire {
        currentWireLayout(config: layoutConfig, transaction: transaction)
    }

    func currentWireLayout(config: LayoutConfig, transaction: UInt32 = 0) -> LayoutWire {
        LayoutGeometry.wireLayout(config: config,
                                  pipLeft: Int16(clamping: pipLeft),
                                  pipTop: Int16(clamping: pipTop),
                                  transaction: transaction)
    }

    /// 规格校正（对照 reconcileCurrentDeviceDisplayProfile）：重装恢复会保留 host 端
    /// 旧显示器档案；旧规格与当前设备不一致时，本会话仅发起一次受控替换。
    /// 注意：DISPLAYS 上报的是实际模式尺寸——2x 档案被系统诚实降为 1x 时上报的是
    /// 逻辑尺寸（AGENTS §4.2），这不算失配，绝不能对它发起替换（否则 host 会在
    /// 「重建→仍是 1x」里循环，推流风暴）。
    private func reconcileCurrentDeviceDisplayProfile(_ list: [DisplayInfo]) {
        let desired = requestedDisplaySpecs().map { SizeSpec(w: Int($0.width), h: Int($0.height)) }
        if desired.isEmpty || list.count < desired.count { return }
        let actual = list.prefix(desired.count).map { SizeSpec(w: Int($0.width), h: Int($0.height)) }
        // HELLO 发的是逻辑请求值，host 建屏前按 16px 对齐；必须按同一规则比较
        func matchesExpected(_ spec: SizeSpec, _ act: SizeSpec) -> Bool {
            if act == spec { return true }
            // 2x 请求被降为 1x：实际模式 = 像素请求的一半再对齐
            let halfAligned = DisplayResolution.hostAligned(spec.w / 2, spec.h / 2)
            return act == SizeSpec(w: halfAligned.0, h: halfAligned.1)
        }
        let ok = zip(desired, actual).allSatisfy { matchesExpected($0.0, $0.1) }
        if ok {
            profileSyncRequested = nil
            return
        }
        let expected = desired.map { spec -> SizeSpec in
            let aligned = DisplayResolution.hostAligned(spec.w, spec.h)
            return SizeSpec(w: aligned.0, h: aligned.1)
        }
        if profileSyncRequested == expected { return }
        profileSyncRequested = expected
        Self.diag.log("correcting stale display profile \(actual) -> \(expected)")
        beginTopologyTransition()
        session?.updateDisplayTopology(specs: requestedDisplaySpecs(),
                                       layout: currentWireLayout())
    }

    private func handleLink(up: Bool) {
        if up {
            linkUp = true
            if !hasVideo && subscribedIds.isEmpty {
                waitingText = "已找到 Mac，正在建立虚拟屏…"
            }
        } else {
            // 掉线：解码器全部释放清 CSD，保持画面冻结比闪绿好。
            // 订阅集保留（对照安卓：只有 closeSession 才清）——host 在 HELLO 重新
            // attach 订阅，客户端清空反而把瞬时断链放大成全量重订阅+闪黑。
            linkUp = false
            hasVideo = false
            topologyTransitionInFlight = false
            topologyExpectedIds = []
            bannerTitle = nil
            bannerDetail = nil
            registry.all.forEach { $0.resetForLinkDown() }
            if phase == .session {
                waitingText = "连接中断，正在重试…"
            }
        }
    }

    private func handleStaleHost() {
        // 切换连接候选而不是用户拔设备：不可发 BYE（可能拆掉当前 Host 恢复中的同设备屏幕）
        Self.diag.log("saved host stale — clearing and rediscovering")
        UserDefaults.standard.removeObject(forKey: "hd.host")
        UserDefaults.standard.removeObject(forKey: "hd.pairingCode")
        endpointText = ""
        pairingCodeText = ""
        session?.stopQuietly()
        session = nil
        phase = .connect
        waitingText = nil
        startDiscovery()
    }

    // MARK: 视图挂接（每区域一份 Representable；光标按 displayId 路由）

    func attachRegion(pipeline: VideoPipeline, surface: VideoLayerView) {
        pipeline.attachSurface(surface)
        videoViewRefs.removeAll { $0.0 == pipeline.displayId || $0.1.value == nil }
        videoViewRefs.append((pipeline.displayId, WeakRef(surface)))
        surface.setStreamSize(w: pipeline.width, h: pipeline.height)
        // 复用的旧 surface（旋转等）重新挂接后要一帧 IDR 立即点亮
        if pipeline.framesRendered > 0 {
            session?.requestKeyframe(displayId: UInt16(clamping: Int(pipeline.displayId)))
        }
    }

    func detachRegion(pipeline: VideoPipeline) {
        pipeline.attachSurface(nil)
        videoViewRefs.removeAll { $0.0 == pipeline.displayId }
    }
}

/// 可比较的屏幕像素尺寸
struct ScreenPixels: Equatable {
    let width: Int
    let height: Int
}

/// 弱引用盒（字典值不能直接 weak）
struct WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

/// 可比较的显示器像素规格
struct SizeSpec: Equatable {
    let w: Int
    let h: Int
}
