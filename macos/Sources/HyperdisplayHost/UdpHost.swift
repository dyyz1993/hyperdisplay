import Foundation
import Darwin

/// 单 UDP socket 的 host 端：接收线程解析报文，发送侧非阻塞 sendto 到指定客户端地址。
/// 客户端注册表由上层（HostApp）管理。
final class UdpHost {
    private let fd: Int32
    private let sendLock = NSLock()
    private(set) var port: UInt16

    /// 解析成功的入站报文 + 来源地址（在接收线程上回调）
    var onPacket: ((Packet, sockaddr_in) -> Void)?

    init(port: UInt16) throws {
        self.port = port
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        fcntl(fd, F_SETFD, FD_CLOEXEC) // exec 重载（档位切换）时必须释放端口，否则新进程只能绑 5278
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
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            // poll 等待代替非阻塞盲收——否则空闲时整核空转（实测曾吃满 100% CPU）
            let rc = poll(&pfd, 1, 500)
            if rc <= 0 { continue }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, saPtr, &fromLen)
                }
            }
            if n <= 0 { continue } // EAGAIN / EINTR / ECONNREFUSED 均忽略
            let data = Data(bytes: buffer, count: n)
            if let packet = Wire.parse(data) {
                onPacket?(packet, from)
            }
        }
    }

    /// 发送已编码的报文；返回 false 表示本次发送失败（丢包语义可接受）
    @discardableResult
    func send(to addr: inout sockaddr_in, _ data: Data) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        let sent = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { addrPtr -> Int in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr -> Int in
                    Darwin.sendto(fd, raw.baseAddress, raw.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    /// 视频分片发送：遇缓冲满（EWOULDBLOCK）小睡重试——把背压转化为流控，
    /// 而不是丢弃剩余分片（自残式丢帧）。重试上限防真实故障死循环。
    func sendWithBackpressure(to addr: inout sockaddr_in, _ data: Data) {
        for _ in 0..<200 {
            if send(to: &addr, data) { return }
            usleep(2000)
        }
    }
}

struct HostError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
