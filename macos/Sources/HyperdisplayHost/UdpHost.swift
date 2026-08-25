import Foundation
import Darwin

/// 单 UDP socket 的 host 端：接收线程解析报文，发送侧非阻塞 sendto 到指定客户端地址。
/// 客户端注册表由上层（HostApp）管理。
final class UdpHost {
    private struct PendingVideoFrame {
        let streamId: UInt32
        var addr: sockaddr_in
        let fragments: [Data]
        let perFragmentDelay: useconds_t
        let keyframe: Bool
    }

    private let fd: Int32
    private let sendLock = NSLock()
    /// 视频分片必须按“完整帧”全局串行出 socket。两个编码器的输出回调会并发：
    /// 若各自逐片发送，帧 A 尚未收完时帧 B 的第一片即可抵达 Android，latest-frame
    /// 接收器便只能丢弃 A，最终两路都没有完整帧可解码。控制包不走此锁。
    private let videoFrameLock = NSLock()
    /// 编码后的 P 帧不能再按“最新帧”覆盖：HEVC/H.264 的下一张 P 帧依赖前一张
    /// 已编码帧，覆盖会在接收端制造引用缺口，使它只能等待 IDR，滚动时便表现为
    /// 周期性卡顿。发送队列因此保持编码顺序；背压在编码前由 `canAcceptVideoFrame`
    /// 丢采集帧，既没有积压，也不破坏码流依赖链。
    private let videoPendingLock = NSLock()
    private var pendingVideoFrames: [PendingVideoFrame] = []
    private var videoDrainActive = false
    private let videoSendQueue = DispatchQueue(label: "hyperdisplay-udp-video-send", qos: .userInteractive)
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

    /// 发送一整个视频帧的全部分片。视频是严格的不可靠 UDP：本机 socket 缓冲
    /// 已满就立即放弃当前帧，绝不 sleep/retry 把旧画面排到新画面前面。下一张
    /// 最新帧会自然覆盖它；只有控制包才允许可靠性语义。
    func sendVideoFrame(to addr: inout sockaddr_in, fragments: [Data], perFragmentDelay: useconds_t) {
        guard !fragments.isEmpty else { return }
        videoFrameLock.lock()
        defer { videoFrameLock.unlock() }
        for (index, fragment) in fragments.enumerated() {
            guard send(to: &addr, fragment) else { return }
            if index < fragments.count - 1 && perFragmentDelay > 0 {
                usleep(perFragmentDelay)
            }
        }
    }

    /// 编码前背压门：最多只允许该屏两帧在等待发送。超过时由调用方丢掉尚未编码的
    /// 新采集帧；这是安全的 latest-frame 策略，因为编码器的参考链完全未发生缺口。
    func canAcceptVideoFrame(streamId: UInt32) -> Bool {
        videoPendingLock.lock()
        let queued = pendingVideoFrames.reduce(into: 0) { count, frame in
            if frame.streamId == streamId { count += 1 }
        }
        videoPendingLock.unlock()
        return queued < 2
    }

    /// 严格保持已编码帧的顺序。`streamId` 仅用于编码前背压计数；v1 只有一个
    /// 平板客户端，所有屏幕共享这一条 UDP 出口，因此全局 FIFO 也避免帧分片交错。
    func enqueueVideoFrame(streamId: UInt32, to addr: sockaddr_in, fragments: [Data],
                           keyframe: Bool, perFragmentDelay: useconds_t) {
        guard !fragments.isEmpty else { return }
        videoPendingLock.lock()
        pendingVideoFrames.append(PendingVideoFrame(
            streamId: streamId, addr: addr, fragments: fragments,
            perFragmentDelay: perFragmentDelay, keyframe: keyframe))
        if !videoDrainActive {
            videoDrainActive = true
            videoSendQueue.async { [weak self] in self?.drainVideoFrames() }
        }
        videoPendingLock.unlock()
    }

    private func drainVideoFrames() {
        while true {
            videoPendingLock.lock()
            guard !pendingVideoFrames.isEmpty else {
                videoDrainActive = false
                videoPendingLock.unlock()
                return
            }
            let pending = pendingVideoFrames.removeFirst()
            videoPendingLock.unlock()
            var frame = pending
            sendVideoFrame(to: &frame.addr, fragments: frame.fragments,
                           perFragmentDelay: frame.perFragmentDelay)
        }
    }
}

struct HostError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
