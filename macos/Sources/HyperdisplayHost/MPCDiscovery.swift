import Foundation
import MultipeerConnectivity

/// Multipeer Connectivity 发现通道（MPC 走 AWDL/Wi-Fi Direct/蓝牙，不经路由器）。
/// 只做「碰头 + 报地址」：广播本机 UDP 端点（IP/端口/配对码），客户端发现后
/// 切回 UDP 高速通道。视频流绝不过 MPC（吞吐撑不起推流）。
///
/// 消息协议：发起方 hello → host 回 offer(ip, port, code)。重发窗口 6s。
final class MPCDiscovery: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                          MCNearbyServiceBrowserDelegate {
    static let serviceType = "hyperdisplay"

    private let myPeerId = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser?
    private let udpPort: UInt16
    private let pairingCode: UInt32
    /// host 模式：只广播不浏览；probe 模式（诊断用）：只浏览不广播
    private let advertiseOnly: Bool
    var onHostEndpoint: ((ip: String, port: UInt16, code: UInt32)) -> Void = { _ in }

    init(udpPort: UInt16, pairingCode: UInt32, advertiseOnly: Bool = true) {
        self.udpPort = udpPort
        self.pairingCode = pairingCode
        self.advertiseOnly = advertiseOnly
        super.init()
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: ["role": "host"],
                                               serviceType: Self.serviceType)
        advertiser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        if !advertiseOnly {
            let b = MCNearbyServiceBrowser(peer: myPeerId, serviceType: Self.serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
        }
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
    }

    // MARK: Advertiser（host 侧）

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("[hyperdisplay] MPC advertise failed: \(error.localizedDescription)")
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 任何邀请都接受：对端是来找地址的
        invitationHandler(true, session)
    }

    // MARK: Browser（probe 侧）

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "host" else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 8)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("[hyperdisplay] MPC browse failed: \(error.localizedDescription)")
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        if advertiseOnly {
            // host 把端点报给刚连上的客户端
            let ip = Self.primaryLANIPv4() ?? "0.0.0.0"
            let payload = "offer|\(ip)|\(udpPort)|\(pairingCode)"
            if let data = payload.data(using: .utf8) {
                try? session.send(data, toPeers: [peerID], with: .reliable)
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let parts = text.split(separator: "|").map(String.init)
        guard parts.count == 4, parts[0] == "offer",
              let port = UInt16(parts[2]), let code = UInt32(parts[3]) else { return }
        onHostEndpoint((parts[1], port, code))
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    static func primaryLANIPv4() -> String? {
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
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                    return ip
                }
                _ = name
            }
            ptr = p.pointee.ifa_next
        }
        return nil
    }
}
