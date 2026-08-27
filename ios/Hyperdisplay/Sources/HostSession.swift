import Foundation
import Network
import os.log

/// 与 macOS host 的 UDP 会话（对照 android/.../HostSession.kt 移植）。
/// 线协议见 Protocol.swift；心跳 / unknown-PONG 判定 / BYE 语义与安卓端一致。
///
/// iOS 版没有 adb 隧道变体（AGENTS.md §1 的有线例外只属于安卓端内置隧道），
/// 阶段一固定走 Wi-Fi UDP。
/// 诊断：Console.app 过滤 subsystem = com.hyperdisplay.session（临时仪表，稳定后移除）。
private let diag = Logger(subsystem: "com.hyperdisplay.session", category: "session")
protocol HostSessionListener: AnyObject {
    /// 各类 host→client 报文统一回调（已在主线程）
    func hostSession(_ session: HostSession, didReceive packet: HostPacket)
    /// 链路状态变化（已在主线程）。false 时应重置解码器并回到等待画面。
    func hostSession(_ session: HostSession, linkChangedUp up: Bool)
    /// 连续 unknown PONG：保存的地址/配对码可能已指向旧 Host，会话无法自愈。
    func hostSessionNeedsRediscovery(_ session: HostSession)
}

final class HostSession {

    struct Config {
        var host: String            // 数字 IPv4 点分四段
        var port: UInt16
        var pairingCode: UInt32
        var deviceId: UInt32
        var fingerprint: UInt64
        var deviceName: String
        /// 客户端屏幕完整像素（长边在前），HELLO 用
        var clientWidth: UInt16
        var clientHeight: UInt16
        /// 目标副屏组（布局换算后的像素规格）与布局快照；可在会话内随 HELLO 更新
        var specs: [RequestedDisplaySpec]
        var layout: LayoutWire
    }

    private var config: Config
    private weak var listener: HostSessionListener?

    /// 校验数字 IPv4（M1 口径，与安卓一致；不做主线程 DNS 解析的对应物是直接拒绝域名）
    static func parseIPv4(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [String] = []
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            // 拒绝前导零的多余形式（如 "01"）
            guard p.count <= 3 && !(p.count > 1 && p.first == "0") || p == "0" else { return nil }
            out.append(String(v))
        }
        return out.joined(separator: ".")
    }

    init?(host: String, port: UInt16, listener: HostSessionListener,
          code: UInt32, deviceId: UInt32, fingerprint: UInt64, deviceName: String,
          clientWidth: UInt16, clientHeight: UInt16,
          specs: [RequestedDisplaySpec], layout: LayoutWire) {
        guard let ip = Self.parseIPv4(host) else {
            NSLog("HostSession: invalid host address %@", host)
            return nil
        }
        self.config = Config(host: ip, port: port, pairingCode: code, deviceId: deviceId,
                             fingerprint: fingerprint, deviceName: deviceName,
                             clientWidth: max(clientWidth, 320), clientHeight: max(clientHeight, 240),
                             specs: Array(specs.prefix(4)), layout: layout)
        self.listener = listener
        self.connection = NWConnection(host: NWEndpoint.Host(ip),
                                       port: NWEndpoint.Port(rawValue: port) ?? 5277,
                                       using: .udp)
    }

    deinit {
        ticker?.cancel()
        connection?.cancel()
    }

    private var connection: NWConnection!
    private let sessionQueue = DispatchQueue(label: "hyperdisplay.session")
    private var ticker: DispatchSourceTimer?
    private var isRunning = false
    /** 连接失败重建的退避计数；.ready 成功后清零 */
    private var restartAttempt = 0
    private var everReady = false
    private var connectionStartedAtMs = UInt64(0)

    // 会话状态（仅 sessionQueue 触碰）
    private var lastPongAtMs = UInt64(0)
    private var lastPingAtMs = UInt64(0)
    private var linkUp = false
    /** unknown PONG 应只覆盖建屏期间的短窗口；连续多次才判定保存的 Host 已过期。 */
    private var consecutiveUnknownPongs = 0
    /**
     * 合法 Host 会在接受 HELLO 后立即回一份 DISPLAYS（即使暂时是空列表）。
     * 因此「收到了 DISPLAYS，但还在建虚拟屏」不能被误判成保存的 Host 过期。
     */
    private var receivedDisplaysForSession = false
    private var pingSeq = AtomicCounter(initial: 1)
    /** 诊断仪表：已收包计数 */
    private var receivedCount = 0
    private var lastStateLogAtMs = UInt64(0)
    private var typeHistogram: [UInt8: Int] = [:]

    func start() {
        isRunning = true
        lastPongAtMs = FrameAssembler.nowMs()
        startConnectionLocked()
    }

    /// 创建并启动底层连接。.failed 时整体重建（模拟器冷启动偶发网络未就绪，
    /// NW 直接报 failed；UDP socket 本身无状态，重建零成本）。
    private func startConnectionLocked() {
        connectionStartedAtMs = FrameAssembler.nowMs()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sessionQueue.async {
                    self.everReady = true
                    self.restartAttempt = 0
                    self.sendHelloLocked()
                    self.startReceiving()
                    self.startTicker()
                }
            case .failed(let error):
                NSLog("HostSession: connection failed %@ — will rebuild", String(describing: error))
                self.sessionQueue.async { self.rebuildConnectionLocked() }
            default:
                break // .preparing / .waiting 属正常（无路由时等网络恢复）
            }
        }
        connection.start(queue: sessionQueue)
    }

    private func rebuildConnectionLocked() {
        guard isRunning else { return }
        restartAttempt += 1
        everReady = false
        let delay = min(5.0, 0.5 * Double(restartAttempt))
        connection?.stateUpdateHandler = nil
        connection?.cancel() // NWConnection 一次性，只能换新实例
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning else { return }
            self.connection = NWConnection(host: NWEndpoint.Host(self.config.host),
                                           port: NWEndpoint.Port(rawValue: self.config.port) ?? 5277,
                                           using: .udp)
            self.startConnectionLocked()
        }
    }

    /// 发 BYE 后关连接（平板真正离开才发；链路切换路径用 `stopQuietly` 复用屏幕身份）
    func goodbyeAndStop() {
        sessionQueue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            ticker?.cancel(); ticker = nil
            // BYE 不能与普通包共用懒发送节奏：立即发出，完成或超时后取消连接。
            var finished = false
            let finish: @Sendable () -> Void = { [weak self] in
                guard let self, !finished else { return }
                finished = true
                self.connection.cancel()
            }
            connection.send(content: ClientWire.bye(), completion: .contentProcessed { _ in finish() })
            sessionQueue.asyncAfter(deadline: .now() + 0.3,
                                    execute: DispatchWorkItem(block: finish))
        }
    }

    /// 不发 BYE 关闭（重新发现路径：不能拆掉当前 Host 正在恢复的同设备屏幕）
    func stopQuietly() {
        sessionQueue.async { [self] in
            tearDown(notifyLinkDown: false)
        }
    }

    // MARK: - 发送

    private func sendLocked(_ data: Data) {
        guard isRunning else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { NSLog("HostSession: send failed %@", String(describing: error)) }
        })
    }

    private func sendHelloLocked() {
        let hello = ClientWire.hello(clientWidth: config.clientWidth, clientHeight: config.clientHeight,
                                     code: config.pairingCode, deviceId: config.deviceId,
                                     fingerprint: config.fingerprint,
                                     deviceName: config.deviceName,
                                     specs: config.specs, layout: config.layout)
        sendLocked(hello)
    }

    /// 布局/尺寸变更不断开 UDP 会话：更新 HELLO 档案并重发，host 保留旧解码
    /// Surface 到新屏首帧（对照 HostSession.updateDisplayTopology）。
    func updateDisplayTopology(specs: [RequestedDisplaySpec], layout: LayoutWire) {
        sessionQueue.async { [self] in
            config.specs = Array(specs.prefix(4))
            config.layout = layout
            sendHelloLocked()
        }
    }

    /// 卸载重装恢复确认（对照 acknowledgeSavedLayout）：host 收到此 ACK 前保护旧档案
    func acknowledgeSavedLayout() {
        sessionQueue.async { [self] in
            sendLocked(ClientWire.layoutRestoreAck())
        }
    }

    /// 单屏模式订阅；displayId < 0 表示请求全部屏的关键帧
    func selectDisplay(id: UInt32) {
        sessionQueue.async { [self] in sendLocked(ClientWire.selectDisplay(id: id)) }
    }

    func subscribeDisplays(ids: [UInt32]) {
        sessionQueue.async { [self] in sendLocked(ClientWire.subscribeDisplays(ids: ids)) }
    }

    func requestKeyframe(displayId: UInt16, broadcastAll: Bool = false) {
        let id: UInt16 = broadcastAll ? ClientWire.displayIdBroadcast : displayId
        let seq = pingSeq.next()
        sessionQueue.async { [self] in
            sendLocked(ClientWire.keyframeReq(seq: seq, displayId: id))
        }
    }

    func sendNack(displayId: UInt16, frameId: UInt32, indices: [UInt16]) {
        sessionQueue.async { [self] in sendLocked(ClientWire.nack(displayId: displayId, frameId: frameId, indices: indices)) }
    }

    // MARK: - 接收

    private func startReceiving() {
        guard isRunning else {
            diag.error("recv: chain stopped (not running)")
            return
        }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 5 {
                self.receivedCount &+= 1
                let t = data[data.startIndex]
                self.typeHistogram[t, default: 0] += 1
                self.dispatchPacket(data)
            } else if let error {
                diag.error("recv error: \(String(describing: error))")
            }
            if self.isRunning {
                self.sessionQueue.async { self.startReceiving() }
            } else {
                diag.error("recv: chain stopped after packet (not running)")
            }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return } // 重建连接后 ticker 跨连接存活，不能叠开
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    /// 心跳 / 掉线重连（host 重启后靠重复 HELLO 重新入会）——250ms 节拍
    private func tick() {
        guard isRunning else { return }
        let now = FrameAssembler.nowMs()
        // 兜底：连接一直没 ready（模拟器冷启动偶发），或长时间零回包（socket 半死）→ 重建
        if !everReady, now &- connectionStartedAtMs > 4_000 {
            NSLog("HostSession: connection never became ready — rebuild")
            rebuildConnectionLocked()
            return
        }
        if everReady, !linkUp, now &- lastPongAtMs > 30_000 {
            NSLog("HostSession: no pong for 30s while down — rebuild socket")
            rebuildConnectionLocked()
            return
        }
        if now &- lastPingAtMs >= Ping.interval {
            lastPingAtMs = now
            sendLocked(ClientWire.ping(seq: pingSeq.next()))
        }
        if now &- lastStateLogAtMs >= 3_000 {
            lastStateLogAtMs = now
            let hist = self.typeHistogram.sorted { $0.key < $1.key }
                .map { String(format: "%02x:%d", $0.key, $0.value) }
                .joined(separator: " ")
            diag.log("tick: linkUp=\(self.linkUp) recv=\(self.receivedCount) listener=\(self.listener != nil) types[\(hist)]")
        }
        let pongAge = now &- lastPongAtMs
        if linkUp && pongAge > 5_000 {
            linkUp = false
            notifyOnMain { $0.hostSession(self, linkChangedUp: false) }
            sendHelloLocked()
        }
        if !linkUp && pongAge > 2_500 {
            // 未连通时持续重试 HELLO（host 重启/换网络后必须能无限重连）
            sendHelloLocked()
            lastPongAtMs = now
        }
    }

    private enum Ping {
        static let interval: UInt64 = 1_500
    }

    private func dispatchPacket(_ data: Data) {
        guard let packet = HostWire.parse(data) else { return }
        switch packet {
        case .displays:
            receivedDisplaysForSession = true
            notifyWithPacket(packet)

        case .displayModeStatus(let transaction, _, _, _, _):
            // 可靠控制状态必须 ACK，Host 才停止短暂重发（阶段二再消费内容）
            sendLocked(ClientWire.displayModeStatusAck(transaction: transaction))
            notifyWithPacket(packet)

        case .cursorImage(let imageId, let index, let count, let w, let h, let hotX, let hotY, let payload):
            if let complete = cursorAssembler.offer(id: imageId, index: Int(index), count: Int(count),
                                                    width: Int(w), height: Int(h),
                                                    hotX: Int(hotX), hotY: Int(hotY), payload: payload) {
                diag.log("cursor image \(complete.imageId) assembled -> ACK")
                sendLocked(ClientWire.cursorImageAck(imageId: complete.imageId))
                notifyOnMain { $0.hostSession(self, didReceive: .cursorBitmap(complete)) }
            } else if imageId != lastCursorImageId {
                lastCursorImageId = imageId
                diag.log("cursor image \(imageId) first fragment idx=\(index)/\(count)")
            }

        case .pong(let known):
            handlePong(known: known)

        default:
            notifyWithPacket(packet)
        }
    }

    private func handlePong(known: Bool) {
        if !known {
            NSLog("HostSession: host has no active displays for this session — re-HELLO")
            sendHelloLocked()
            // 不把 unknown PONG 当作“链路已正常”：等待下一枚 known PONG 才宣布连通，
            // 避免空会话遮住等待提示（注意这里不回调 linkChangedUp(false)）。
            linkUp = false
            consecutiveUnknownPongs += 1
            if consecutiveUnknownPongs >= 6 && !receivedDisplaysForSession {
                consecutiveUnknownPongs = 0
                notifyOnMain { $0.hostSessionNeedsRediscovery(self) }
            } else if receivedDisplaysForSession {
                consecutiveUnknownPongs = 0
            }
            return
        }
        consecutiveUnknownPongs = 0
        if !linkUp {
            linkUp = true
            notifyOnMain { $0.hostSession(self, linkChangedUp: true) }
        }
        lastPongAtMs = FrameAssembler.nowMs()
    }

    // MARK: - 辅助

    private var cursorAssembler = CursorImageAssembler()
    private var lastCursorImageId = UInt32(0)

    private func tearDown(notifyLinkDown: Bool) {
        guard isRunning else {
            if notifyLinkDown && linkUp { linkUp = false; notifyOnMain { $0.hostSession(self, linkChangedUp: false) } }
            return
        }
        isRunning = false
        ticker?.cancel(); ticker = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if notifyLinkDown {
            notifyOnMain { $0.hostSession(self, linkChangedUp: false) }
        }
    }

    private func notifyOnMain(_ block: @escaping (HostSessionListener) -> Void) {
        guard let listener else { return }
        DispatchQueue.main.async { block(listener) }
    }

    private func notifyWithPacket(_ packet: HostPacket) {
        guard let listener else { return }
        DispatchQueue.main.async { listener.hostSession(self, didReceive: packet) }
    }
}

// MARK: - 光标样式可靠重组（对照 HostSession.kt 内部类）

struct CursorImage {
    let imageId: UInt32
    let width: Int
    let height: Int
    let hotX: Int
    let hotY: Int
    let pixels: Data
}

/**
 * 光标样式是可靠的小状态，不应塞进视频 latest-frame 组装器。Host 发送一组不超过
 * 1KB 的 UDP 分片；只有完整 BGRA 位图才替换当前样式，乱序/重复包不会闪回旧光标。
 */
final class CursorImageAssembler {
    private var assemblingId = UInt32(0)
    private var deliveredId = UInt32.max // 「未投递过」哨兵
    private var width = 0, height = 0, hotX = 0, hotY = 0
    private var parts: [Data?] = []
    private var received = 0

    func offer(id: UInt32, index: Int, count: Int, width w: Int, height h: Int,
               hotX hx: Int, hotY hy: Int, payload: Data) -> CursorImage? {
        guard (1...64).contains(count), index >= 0, index < count,
              (1...256).contains(w), (1...256).contains(h), w * h * 4 <= 32 * 1024 else { return nil }
        // Host imageId 单调递增；旧重传到得更晚时绝不覆盖已经绘制的新形状。
        if deliveredId != .max && id <= deliveredId { return nil }
        if id != assemblingId {
            assemblingId = id
            width = w; height = h; hotX = hx; hotY = hy
            parts = Array<Data?>(repeating: nil, count: count)
            received = 0
        }
        if w != width || h != height || hx != hotX || hy != hotY || parts.count != count { return nil }
        if parts[index] == nil {
            parts[index] = payload
            received += 1
        }
        guard received == count else { return nil }
        let expected = width * height * 4
        var joined = Data(capacity: expected)
        for part in parts {
            guard let bytes = part else { return nil }
            joined.append(bytes)
        }
        guard joined.count == expected else { return nil }
        deliveredId = id
        return CursorImage(imageId: id, width: width, height: height, hotX: hotX, hotY: hotY, pixels: joined)
    }
}

// MARK: - 原子计数器（ping 序号）

final class AtomicCounter {
    private var value: UInt32
    private let lock = NSLock()

    init(initial: UInt32) { value = initial }

    func next() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}
