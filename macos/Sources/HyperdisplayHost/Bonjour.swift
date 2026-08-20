import Foundation
import dnssd

/// Bonjour 服务广播（_hyperdisplay._udp）。
/// 用 dnssd 的 DNSServiceRegister：只注册服务记录，不占用 socket（数据通道仍是 BSD UDP）。
final class BonjourAdvertiser {
    static let serviceType = "_hyperdisplay._udp"

    private var service: DNSServiceRef?
    private let queue = DispatchQueue(label: "hyperdisplay.bonjour")

    /// name 默认 "Hyperdisplay <设备名>"，端口冲突时 Bonjour 自动改名。
    /// TXT 记录携带配对码：单用户自家用网络（AGENTS.md §7.4），发现即得码，
    /// 零点击路径不因配对中断。
    func start(name: String, port: UInt16, txt: [String: String] = [:]) -> Bool {
        let callback: DNSServiceRegisterReply? = nil
        var ref: DNSServiceRef?
        // TXT = 一串 length-prefixed "key=value"
        let txtBytes = txt.flatMap { pair -> [UInt8] in
            let s = "\(pair.key)=\(pair.value)"
            return [UInt8(s.utf8.count)] + Array(s.utf8)
        }
        let status = DNSServiceRegister(
            &ref,
            0,                      // flags
            0,                      // 所有接口
            name,
            Self.serviceType,
            nil,                    // domain = default
            nil,                    // host = 本机
            port.bigEndian,         // 网络字节序
            UInt16(txtBytes.count), // TXT 长度
            txtBytes.isEmpty ? nil : txtBytes,
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
