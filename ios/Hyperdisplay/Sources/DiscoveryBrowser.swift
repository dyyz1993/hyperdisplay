import Foundation
import Network
import Darwin

/// 局域网发现 hyperdisplay host（_hyperdisplay._udp，对照 android/.../NsdFinder.kt）。
/// 发现 → 解析 IPv4 端点 → 回调 (名字, ip, port, 配对码)。iOS 无 USB 网络共享，
/// 不需要安卓端的传输类型判定。
///
/// mDNS 依赖路由器在设备间转发组播（IGMP Snooping / 有线无线混布时常被丢弃），
/// 所以 mDNS 一段时间无结果时自动降级为「单播网段扫描」：对 /24 逐个发 PING，
/// host 的 PONG 应答即暴露其地址——单播不走组播，权限内即可用。
struct DiscoveredHost: Identifiable, Equatable {
    var id: String { "\(name)|\(host)|\(port)" }
    let name: String
    let host: String
    let port: UInt16
    let pairingCode: UInt32
}

final class DiscoveryBrowser {

    static let serviceType = "_hyperdisplay._udp"
    static let defaultPort: UInt16 = 5277

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "hyperdisplay.discovery")
    private var resolveConnections: [String: NWConnection] = [:]
    /// 单次解析限时；超时取消并在下次浏览刷新时重试
    private let resolveTimeout: TimeInterval = 4

    /// 主线程回调；同一主机重复出现时更新条目
    var onUpdate: (([DiscoveredHost]) -> Void)?

    private var hosts: [DiscoveredHost] = [] // 仅主线程读写（回调已收敛到主队列）

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                NSLog("DiscoveryBrowser: failed %@", String(describing: error))
                self?.onError?("发现启动失败：可改用手动输入 IP")
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolveConnections.values.forEach { $0.cancel() }
        resolveConnections.removeAll()
        stopSweep()
    }

    // MARK: - 单播网段扫描（mDNS 无结果时的兜底）

    private var sweepSocket: Int32 = -1
    private var sweepActive = false

    /// mDNS 启动 4.5s 仍无结果时调用：对所在 /24 逐个发 PING（12ms 间隔，约 3s），
    /// 监听 4s 内的 PONG 应答。host 对任何来源都会回 PONG（unknown 标志位），
    /// 应答地址即 Mac。单播 UDP，不需要组播权限。
    func startSweepFallback() {
        guard browser != nil, !sweepActive else { return } // mDNS 仍在跑才值得兜底
        guard let (basePrefix, _) = Self.localLANIPv4() else {
            onError?("未获取到 Wi-Fi 地址：请确认已连接无线网络")
            return
        }
        sweepActive = true
        let queue = DispatchQueue(label: "hyperdisplay.sweep")
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { sweepActive = false; return }
        sweepSocket = fd
        var rcvTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [weak self] in
            defer { close(fd); self?.sweepActive = false; self?.sweepSocket = -1 }
            let ping: [UInt8] = [0x13, 0, 0, 0, 1]
            for i in 1...254 {
                guard self?.sweepActive == true else { return }
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(5277).bigEndian
                inet_pton(AF_INET, "\(basePrefix)\(i)", &addr.sin_addr)
                withUnsafeBytes(of: ping) { raw in
                    withUnsafePointer(to: &addr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, raw.baseAddress, ping.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                usleep(12_000)
            }
            var buf = [UInt8](repeating: 0, count: 64)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let deadline = Date().addingTimeInterval(4)
            var reported = Set<String>()
            while Date() < deadline, self?.sweepActive == true {
                let n = withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
                    }
                }
                guard n == 6, buf[0] == 0x06 else { continue } // PONG
                var addrIn = from.sin_addr
                var cStr = [CChar](repeating: 0, count: 16)
                inet_ntop(AF_INET, &addrIn, &cStr, socklen_t(16))
                let ip = String(cString: cStr)
                guard ip != basePrefix + "1", !reported.contains(ip) else { continue }
                reported.insert(ip)
                let host = DiscoveredHost(name: "Mac（自动发现）", host: ip,
                                          port: Self.defaultPort, pairingCode: 0)
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdate?([host])
                }
            }
        }
    }

    func stopSweep() {
        sweepActive = false
        if sweepSocket >= 0 {
            close(sweepSocket)
            sweepSocket = -1
        }
    }

    /// 本机 en 接口的 IPv4 与 /24 前缀。跳过回环与 169.254 链路本地自分配地址
    /// （DHCP 失败时的兜底，不在真实局域网内，扫它毫无意义）。
    static func localLANIPv4() -> (prefix: String, ip: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                var cStr = [CChar](repeating: 0, count: 16)
                inet_ntop(AF_INET, &addr.sin_addr, &cStr, socklen_t(16))
                let ip = String(cString: cStr)
                let name = String(cString: ifa.ifa_name)
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254."), name.hasPrefix("en") {
                    let parts = ip.split(separator: ".")
                    if parts.count == 4 {
                        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
                        return (prefix, ip)
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return nil
    }

    /// 是否只有 169.254 链路本地地址（Wi-Fi 未真正接入局域网的信号）
    static func hasOnlyLinkLocal() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        var sawIPv4 = false
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                var cStr = [CChar](repeating: 0, count: 16)
                inet_ntop(AF_INET, &addr.sin_addr, &cStr, socklen_t(16))
                let ip = String(cString: cStr)
                if !ip.hasPrefix("127.") {
                    sawIPv4 = true
                    if !ip.hasPrefix("169.254.") { return false }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return sawIPv4
    }

    var onError: ((String) -> Void)?

    // MARK: - 解析

    private func handle(results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            guard !resolveConnections.keys.contains(name) else { continue }

            var code: UInt32 = 0
            // txtRecord 直接挂在服务 endpoint 上（iOS 16+），下标返回 String
            if let record = result.endpoint.txtRecord,
               let text = record["code"],
               let parsed = UInt32(text.trimmingCharacters(in: CharacterSet.whitespaces)) {
                // TXT 携带配对码（单用户家用网络）：发现即得码，零点击
                code = parsed
            }
            resolveService(name: name, endpoint: result.endpoint, pairingCode: code)
        }
        // 服务消失的条目等下一次正常地址确认再剔除（避免 UDP 抖动误删正在用的主机）
    }

    private func resolveService(name: String, endpoint: NWEndpoint, pairingCode: UInt32) {
        let conn = NWConnection(to: endpoint, using: .udp)
        resolveConnections[name] = conn
        var finished = false

        func finish(_ result: DiscoveredHost?) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { [weak self] in
                self?.resolveConnections.removeValue(forKey: name)
                guard let self, let result else { return }
                if let index = self.hosts.firstIndex(where: { $0.name == result.name }) {
                    if self.hosts[index] != result {
                        self.hosts[index] = result
                        self.onUpdate?(self.hosts)
                    }
                } else {
                    self.hosts.append(result)
                    self.onUpdate?(self.hosts)
                }
            }
        }

        /// 触发路径建立并读取解析出的远端地址：先靠一次 send 完成回调，
        /// 兜底再轮询 currentPath（UDP 服务端点有时在 ready 后才填充）。
        func awaitRemoteEndpoint(attempt: Int) {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard !finished, !attemptIsExhausted(attempt) else {
                    finish(nil)
                    return
                }
                if let remote = conn.currentPath?.remoteEndpoint,
                   let endpoint = Self.extractEndpoint(from: "\(remote)") {
                    finish(DiscoveredHost(name: name, host: endpoint.host,
                                          port: endpoint.port ?? Self.defaultPort,
                                          pairingCode: pairingCode))
                    return
                }
                awaitRemoteEndpoint(attempt: attempt + 1)
            }
        }

        func attemptIsExhausted(_ attempt: Int) -> Bool { attempt >= 15 }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: Data([0x00]), completion: .contentProcessed { _ in
                    if let remote = conn.currentPath?.remoteEndpoint,
                       let endpoint = Self.extractEndpoint(from: "\(remote)") {
                        finish(DiscoveredHost(name: name, host: endpoint.host,
                                              port: endpoint.port ?? Self.defaultPort,
                                              pairingCode: pairingCode))
                    } else {
                        awaitRemoteEndpoint(attempt: 0)
                    }
                })
            case .failed, .cancelled:
                break // 超时/完成路径统一收尾，这里不再触碰 UI 状态
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + resolveTimeout) { [weak self] in
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { self?.resolveConnections.removeValue(forKey: name) }
        }
    }

    /// NWPath.remoteEndpoint 没有公开结构化访问；从描述文本里抠出 IPv4 端点。
    /// 描述形如 `IPv4(192.168.1.23:5277)` / `IPv4(#.#.#.#)`。
    /// 仅支持数字 IPv4，与 M1 手输口径一致。返回 nil 表示该路径不可用于 v1。
    static func extractEndpoint(from description: String) -> (host: String, port: UInt16?)? {
        guard let open = description.range(of: "IPv4(") else { return nil }
        guard let close = description.range(of: ")",
                                            range: open.upperBound..<description.endIndex) else { return nil }
        let inner = description[open.upperBound..<close.lowerBound]
        let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let host = String(parts[0])
        // M1 口径：点分四段数字地址
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({UInt8($0) != nil}) else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) : nil
        return (host, port)
    }
}
