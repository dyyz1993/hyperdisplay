import Foundation
import Network

/// 局域网发现 hyperdisplay host（_hyperdisplay._udp，对照 android/.../NsdFinder.kt）。
/// 发现 → 解析 IPv4 端点 → 回调 (名字, ip, port, 配对码)。iOS 无 USB 网络共享，
/// 不需要安卓端的传输类型判定。
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
