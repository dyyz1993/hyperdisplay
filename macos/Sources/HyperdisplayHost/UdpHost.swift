import Foundation
import Darwin

/// 单 UDP socket 的 host 端：接收线程解析报文，发送侧非阻塞 sendto。
/// 用 BSD socket 而非 Network.framework，避免其对端不可达时静默 cancel 的问题。
final class UdpHost {
    private let fd: Int32
    private let sendLock = NSLock()
    private let addrLock = NSLock()
    private var clientAddress: sockaddr_in?
    private(set) var port: UInt16

    /// 解析成功的入站报文 + 来源地址（在接收线程上回调）
    var onPacket: ((Packet, sockaddr_in) -> Void)?

    init(port: UInt16) throws {
        self.port = port
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw HostError("socket() failed: \(String(cString: strerror(errno)))") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        var boundPort = port
        var bindStatus: Int32 = -1
        for candidate in [port, UInt16(port + 1)] {
            addr.sin_port = candidate.bigEndian
            bindStatus = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindStatus == 0 { boundPort = candidate; break }
        }
        guard bindStatus == 0 else {
            close(fd)
            throw HostError("bind UDP \(port) failed: \(String(cString: strerror(errno)))")
        }
        self.port = boundPort
    }

    func start() {
        let thread = Thread(block: { [weak self] in self?.receiveLoop() })
        thread.name = "hyperdisplay-udp-recv"
        thread.stackSize = 1 << 19
        thread.start()
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, saPtr, &fromLen)
                }
            }
            if n <= 0 { continue } // EAGAIN / EINTR / ECONNREFUSED 均忽略，继续收
            let data = Data(bytes: buffer, count: n)
            if let packet = Wire.parse(data) {
                onPacket?(packet, from)
            }
        }
    }

    func setClientAddress(_ addr: sockaddr_in) {
        addrLock.lock()
        clientAddress = addr
        addrLock.unlock()
    }

    var clientAddressString: String? {
        addrLock.lock()
        defer { addrLock.unlock() }
        guard let a = clientAddress else { return nil }
        var addr = a
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return String(cString: host)
    }

    /// 发送已编码的报文到当前客户端；返回 false 表示本次发送失败（丢包语义可接受）
    @discardableResult
    func sendToClient(_ data: Data) -> Bool {
        addrLock.lock()
        var addr = clientAddress
        addrLock.unlock()
        guard var addr else { return false }
        sendLock.lock()
        defer { sendLock.unlock() }
        let sent = data.withUnsafeBytes { raw -> Int in
            withUnsafeMutablePointer(to: &addr) { addrPtr -> Int in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr -> Int in
                    Darwin.sendto(fd, raw.baseAddress, raw.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    /// 发送一整帧视频（分片）。非阻塞下遇 EWOULDBLOCK 直接放弃本帧剩余分片：
    /// 对不可靠通道而言等同丢包，客户端 latest-frame 策略会跟随下一帧。
    func sendVideoFrame(frameId: UInt32, keyframe: Bool, payload: Data) {
        for frag in Wire.videoFrags(frameId: frameId, keyframe: keyframe, payload: payload) {
            if !sendToClient(frag) { return }
        }
    }
}

struct HostError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
