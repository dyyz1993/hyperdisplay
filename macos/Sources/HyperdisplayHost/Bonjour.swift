import Foundation
import dnssd

/// Bonjour 服务广播（_hyperdisplay._udp）。
/// 用 dnssd 的 DNSServiceRegister：只注册服务记录，不占用 socket（数据通道仍是 BSD UDP）。
final class BonjourAdvertiser {
    static let serviceType = "_hyperdisplay._udp"

    private var service: DNSServiceRef?
    private let queue = DispatchQueue(label: "hyperdisplay.bonjour")

    /// name 默认 "Hyperdisplay <设备名>"，端口冲突时 Bonjour 自动改名
    func start(name: String, port: UInt16) -> Bool {
        let callback: DNSServiceRegisterReply? = nil
        var ref: DNSServiceRef?
        let status = DNSServiceRegister(
            &ref,
            0,                      // flags
            0,                      // 所有接口
            name,
            Self.serviceType,
            nil,                    // domain = default
            nil,                    // host = 本机
            port.bigEndian,         // 网络字节序
            0,                      // TXT 长度
            nil,                    // TXT 记录
            callback,
            nil                     // context
        )
        guard status == kDNSServiceErr_NoError, let ref else {
            NSLog("[hyperdisplay] Bonjour register failed: \(status)")
            return false
        }
        service = ref
        DNSServiceSetDispatchQueue(ref, queue)
        NSLog("[hyperdisplay] Bonjour advertising '\(name)' \(Self.serviceType) port \(port)")
        return true
    }

    func stop() {
        if let service {
            DNSServiceRefDeallocate(service)
        }
        service = nil
    }

    deinit { stop() }
}
