import Foundation
import SwiftUI
import UIKit
import AVFoundation
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

    /// 连接页输入框（UserDefaults 同步）
    @Published var endpointText: String = UserDefaults.standard.string(forKey: "hd.host") ?? ""
    @Published var pairingCodeText: String = {
        let code = UserDefaults.standard.integer(forKey: "hd.pairingCode")
        return code > 0 ? String(code) : ""
    }()
    @AppStorage("hd.showStats") var showStats = false
    @Published var statsLine = ""

    // MARK: 内部状态

    private var session: HostSession?
    private var pipelines: [UInt32: VideoPipeline] = [:]
    private let browser = DiscoveryBrowser()
    private var stallTimer: Timer?
    /// 后台被迫断开过 → 回前台无缝重连（host 侧 EDID 档案还原）
    private var reconnectOnForeground = false
    private var lastStatTickAtMs = UInt64(0)
    private var lastRenderedSnapshot: [UInt32: Int] = [:]
    // 视图挂接：每区域一份（光标按 displayId 路由）
    var cursorOverlayRefs: [(UInt32, WeakRef<CursorOverlayView>)] = []

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
    }

    deinit {
        session = nil // goodbye 走显式路径；deinit 只保证连接取消
        stallTimer?.invalidate()
        browser.stop()
    }

    // MARK: - 连接入口

    func bootstrap() {
        UIApplication.shared.isIdleTimerDisabled = true
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
        lastSentPixels = Self.screenPixels()
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
        pipelines.values.forEach { $0.teardown() }
        pipelines.removeAll()
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
        // mDNS 依赖路由器在设备间转发组播（有线↔无线混布/IGMP Snooping 时常丢弃），
        // 4.5s 无结果就降级为单播网段扫描——host 的 PONG 应答即暴露其地址。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self, self.phase == .connect, self.discoveredHosts.isEmpty else { return }
            Self.diag.log("mDNS no results — starting unicast subnet sweep")
            self.statusText = "正在直连扫描网段…"
            self.browser.startSweepFallback()
        }
    }

    private func stopDiscovery() {
        browser.stop()
        discoveredHosts = []
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
        for p in pipelines.values { p.assembler.stallCheck() }
        // 布局替换横幅：整组新屏都出过一帧才能收（旧屏仍在播放时不能提前撤）；
        // 但 host 只建出部分屏（或建屏失败）时不能永远挂着——12s 强制收起。
        if topologyTransitionInFlight {
            if !topologyExpectedIds.isEmpty,
               topologyExpectedIds.allSatisfy({ (pipelines[$0]?.framesRendered ?? 0) > 0 }) {
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
        let pixels = Self.screenPixels()
        guard pixels != lastSentPixels else { return }
        rotationDebounceTask?.cancel()
        rotationDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let stable = Self.screenPixels()
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
        var parts: [String] = []
        parts.append(linkUp ? "链路 OK" : "未连通")
        for p in pipelines.values.sorted(by: { $0.displayId < $1.displayId }) {
            let previous = lastRenderedSnapshot[p.displayId] ?? p.framesRendered
            let fps = p.framesRendered &- previous
            lastRenderedSnapshot[p.displayId] = p.framesRendered
            parts.append("屏\(p.displayId) \(p.width)x\(p.height) ~\(fps)fps 渲\(p.framesRendered)")
        }
        statsLine = parts.joined(separator: "  ")
    }

    // MARK: - 工具

    func pipelineOf(id: UInt32) -> VideoPipeline {
        if let existing = pipelines[id] { return existing }
        let p = VideoPipeline(displayId: id, callbacks: .init(
            requestKeyframe: { [weak self] displayId in
                self?.session?.requestKeyframe(displayId: UInt16(clamping: Int(displayId)))
            },
            sendNack: { [weak self] displayId, frameId, missing in
                self?.session?.sendNack(displayId: UInt16(clamping: Int(displayId)),
                                        frameId: frameId, indices: missing)
            },
            firstFrameRendered: { [weak self] in
                self?.hasVideo = true
                self?.waitingText = nil
            }
        ))
        pipelines[id] = p
        return p
    }

    func pipeline(for id: UInt32) -> VideoPipeline? { pipelines[id] }

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

extension AppModel: HostSessionListener {

    nonisolated func hostSession(_ session: HostSession, didReceive packet: HostPacket) {
        Task { @MainActor in self.handle(packet: packet) }
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

        case .config(let displayId, _, let paramSets):
            Self.diag.log("CONFIG display=\(displayId) csd=\(paramSets.count) bytes")
            pipelineOf(id: UInt32(displayId)).handleConfig(paramSets)

        case .videoFragment(let displayId, let frameId, let fragIdx, let fragCount,
                            let keyframe, let payload):
            pipelineOf(id: UInt32(displayId)).handleFragment(frameId: Int64(frameId),
                                                             fragIdx: Int(fragIdx),
                                                             fragCount: Int(fragCount),
                                                             keyframe: keyframe, payload: payload)

        case .displays(let list):
            guard !list.isEmpty else {
                // Host 尚在建虚拟屏：保持等待提示，不误判成保存的 Host 过期
                waitingText = linkUp ? "Mac 正在建立虚拟屏…" : "等待 Mac 主机…"
                return
            }
            handleDisplays(list)

        case .cursor(let displayId, let x, let y):
            if displayId == 0 {
                cursorOverlays.values.forEach { $0.hide() }
            } else if let overlay = cursorOverlays[UInt32(displayId)] {
                overlay.moveTo(streamX: x, streamY: y)
            }

        case .cursorBitmap(let image):
            // 系统光标位图是全局一份；各区域各自绘制，位置仍由 cursor 包按 displayId 驱动
            for overlay in cursorOverlays.values {
                overlay.setSystemCursorBitmap(width: image.width, height: image.height,
                                              hotX: image.hotX, hotY: image.hotY,
                                              bgra: image.pixels)
            }

        case .savedLayout(let wire):
            handleSavedLayout(wire)

        case .displayModeStatus(let transaction, let status, _, let requestedScale, let actualScale):
            handleDisplayModeStatus(transaction: transaction, status: status,
                                    requestedScale: requestedScale, actualScale: actualScale)

        case .cursorImage, .inputAck, .pong:
            break // 光标分片由 HostSession 组装；pong 状态机也在会话层内部
        }
    }

    /// 多屏订阅（对照 MainActivity.onDisplays）：按当前布局需要的屏数取前 n 块，
    /// 订阅集不变时绝不重复 selectDisplay/requestKeyframe——host 会为每次订阅变更
    /// 重推 DISPLAYS+WELCOME，无条件的重订阅会形成 kHz 级正反馈风暴。
    private func handleDisplays(_ list: [DisplayInfo]) {
        let wanted = max(LayoutGeometry.requestedSpecs(config: layoutConfig,
                                                       screenW: Self.screenPixels().width,
                                                       screenH: Self.screenPixels().height).count, 1)
        let selected = list.prefix(wanted)
        let desiredIds = selected.map(\.id)
        awaitingSecondDisplay = desiredIds.count < wanted

        if subscribedIds.isEmpty {
            subscribedIds = desiredIds
            resetPipelines(keep: [])
            beginTopologyArming(expectedIds: Set(desiredIds))
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
        } else {
            awaitingSecondDisplay = false
        }

        activeDisplayId = subscribedIds.first
        if subscribedIds.count == 1 {
            session?.selectDisplay(id: subscribedIds[0])
        } else if !subscribedIds.isEmpty {
            session?.subscribeDisplays(ids: subscribedIds)
        }
        subscribedIds.forEach { session?.requestKeyframe(displayId: UInt16(clamping: Int($0))) }
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
        for p in pipelines.values where !keep.contains(p.displayId) {
            p.teardown()
        }
        pipelines = pipelines.filter { keep.contains($0.key) }
    }

    // MARK: 布局换算

    func requestedDisplaySpecs() -> [RequestedDisplaySpec] {
        requestedDisplaySpecs(config: layoutConfig)
    }

    func requestedDisplaySpecs(config: LayoutConfig) -> [RequestedDisplaySpec] {
        let px = Self.screenPixels()
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
            // 订阅集一并清空：host 重启后会话是全新的，DISPLAYS 到达时需要完整重订阅。
            linkUp = false
            hasVideo = false
            subscribedIds = []
            topologyTransitionInFlight = false
            topologyExpectedIds = []
            bannerTitle = nil
            bannerDetail = nil
            pipelines.values.forEach { $0.resetForLinkDown() }
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

    var cursorOverlays: [UInt32: CursorOverlayView] {
        cursorOverlayRefs = cursorOverlayRefs.filter { $0.1.value != nil }
        return Dictionary(cursorOverlayRefs.map { ($0.0, $0.1.value!) }, uniquingKeysWith: { _, b in b })
    }

    func attachRegion(pipeline: VideoPipeline, surface: VideoLayerView, cursor: CursorOverlayView) {
        pipeline.surfaceView = surface
        cursorOverlayRefs.removeAll { $0.0 == pipeline.displayId }
        cursorOverlayRefs.append((pipeline.displayId, WeakRef(cursor)))
        // 系统光标位图到达前先给一个可辨认的本地箭头兜底
        cursor.useFallbackArrow()
        cursor.setStreamSize(w: pipeline.width, h: pipeline.height)
        // 复用的旧 surface（旋转等）重新挂接后要一帧 IDR 立即点亮
        if pipeline.framesRendered > 0 {
            session?.requestKeyframe(displayId: UInt16(clamping: Int(pipeline.displayId)))
        }
    }

    func detachRegion(pipeline: VideoPipeline) {
        pipeline.surfaceView = nil
        cursorOverlayRefs.removeAll { $0.0 == pipeline.displayId }
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
