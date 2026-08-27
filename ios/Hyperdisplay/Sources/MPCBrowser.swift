import Foundation
import MultipeerConnectivity

/// iOS 侧 MPC 发现（对照 host 侧 MPCDiscovery）：浏览附近的 Mac → 邀请入会 →
/// 收 offer(ip, port, code) → 转成 DiscoveredHost 走常规 UDP 连接。
/// MPC 走 AWDL/直连不经路由器，AP 隔离网络里是唯一能自动发现的路。
final class MPCBrowser: NSObject, MCNearbyServiceBrowserDelegate, MCSessionDelegate {

    static let shared = MPCBrowser()

    private let myPeerId = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: myPeerId, securityIdentity: nil,
                                         encryptionPreference: .none)
    private var browser: MCNearbyServiceBrowser?
    private var pendingInvites: Set<String> = []

    /// 主线程回调；host 配对码来自 offer（可信来源=同一 MPC 会话）
    var onHost: ((DiscoveredHost) -> Void)?

    func start() {
        stop()
        let b = MCNearbyServiceBrowser(peer: myPeerId, serviceType: MPCDiscoveryServiceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        pendingInvites.removeAll()
    }
}

let MPCDiscoveryServiceType = "hyperdisplay"

extension MPCBrowser {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "host" else { return }
        guard !pendingInvites.contains(peerID.displayName) else { return }
        pendingInvites.insert(peerID.displayName)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 8)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        pendingInvites.remove(peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("MPCBrowser: browse failed \(error.localizedDescription)")
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {}

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let parts = text.split(separator: "|").map(String.init)
        guard parts.count == 4, parts[0] == "offer",
              let port = UInt16(parts[2]), let code = UInt32(parts[3]) else { return }
        let host = DiscoveredHost(name: "\(peerID.displayName)（近场发现）",
                                  host: parts[1], port: port, pairingCode: code)
        DispatchQueue.main.async { [weak self] in
            self?.onHost?(host)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
