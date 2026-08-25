import Foundation
import AppKit

/// USB 隧道桥（内置，取代 Scripts/usb-start.sh + usb-tunnel.py + usb-watch.sh）：
/// - TCP 127.0.0.1:5280 ↔ UDP 127.0.0.1:<udpPort> 帧互转。帧格式 [len u32 LE][payload]；
///   每条 TCP 连接配一个独立 UDP 源端口，host 回包天然按源端口路由回各自连接
///   （探测与正式会话可并存）。UDP 接收缓冲 4MB：关键帧突发到达不被内核静默丢片
///   （沿用 python 版实测结论）。
/// - 周期 `adb devices` 轮询：对每台在线设备（重新）注册 `adb reverse tcp:5280
///   tcp:5280`——reverse 不随设备重插存活，重注册必须做；这也是插线事件的来源
///   （平板侧 POWER_CONNECTED 广播静默探测本端口）。
/// 平板插线 → adbd 监听 5280 → app 探测握手成功 → 通知拉起 → 智能连接（AGENTS.md §7.1）。
final class UsbTunnelController {
    static let tcpPort: UInt16 = 5280
    private(set) var deviceCount = 0
    private(set) var adbAvailable = UsbTunnelController.locateAdb() != nil
    var onDeviceCountChange: (() -> Void)?

    private var listenFd: Int32 = -1
    private var acceptThread: Thread?
    private var pollTimer: Timer?
    private let lock = NSLock()
    private var connFds: Set<Int32> = []
    private var udpPort: UInt16 = 5277

    // MARK: 生命周期

    func start(udpPort: UInt16) {
        self.udpPort = udpPort
        startListener()
        startPolling()
    }

    func stop() {
        if let timer = pollTimer { timer.invalidate(); pollTimer = nil }
        let fd = listenFd
        listenFd = -1
        if fd >= 0 { _ = close(fd) } // accept 线程随 fd 关闭退出
        lock.lock()
        let fds = connFds
        connFds.removeAll()
        lock.unlock()
        for cfd in fds { _ = close(cfd) } // 各连接线程读写出错后自行收尾
    }

    // MARK: TCP ↔ UDP 桥

    private func startListener() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        fcntl(fd, F_SETFD, FD_CLOEXEC) // 同上：exec 重载后 5280 必须可重绑
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = Self.tcpPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindOK = withUnsafePointer(to: &addr) {
            bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
        guard bindOK, listen(fd, 4) == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            NSLog("[hyperdisplay] USB tunnel: bind 127.0.0.1:%d failed (%@) — 旧 usb-tunnel.py 还在跑？", Self.tcpPort, err)
            return
        }
        listenFd = fd
        NSLog("[hyperdisplay] USB tunnel: TCP 127.0.0.1:%d <-> UDP 127.0.0.1:%d", Self.tcpPort, udpPort)
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "usb-tunnel-accept"
        t.start()
        acceptThread = t
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = accept(listenFd, &clientAddr, &len)
            if cfd < 0 {
                if errno == EINTR { continue }
                return // listen fd 已关闭（stop()）
            }
            var one: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            // 平板断开瞬间 send() 会触发 SIGPIPE 默认终止整个 host——必须关掉
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); connFds.insert(cfd); lock.unlock()
            // 每连接独立线程（python 原版语义）：accept 循环绝不能被持久会话阻塞，
            // 否则后续探测/会话全堵在 backlog 里（连接超时、回程延迟秒级）
            let t = Thread { [weak self] in self?.handleClient(cfd) }
            t.name = "usb-tunnel-conn"
            t.start()
        }
    }

    private func handleClient(_ cfd: Int32) {
        // 独立 UDP 源端口
        let ufd = socket(AF_INET, SOCK_DGRAM, 0)
        guard ufd >= 0 else { close(cfd); return }
        var rcvbuf: Int32 = 4 * 1024 * 1024
        setsockopt(ufd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        var any = sockaddr_in()
        any.sin_family = sa_family_t(AF_INET)
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        any.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindOK = withUnsafePointer(to: &any) {
            bind(ufd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
        guard bindOK else { close(ufd); close(cfd); return }
        var dest = any
        dest.sin_port = udpPort.bigEndian

        let udpWriter = Thread { [weak self] in
            // UDP → TCP：长度前缀回写
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(ufd, &buf, buf.count, 0)
                if n <= 0 { break }
                var lenLE = UInt32(n).littleEndian
                var sent = send(cfd, &lenLE, 4, 0)
                if sent <= 0 { break }
                sent = send(cfd, &buf, n, 0)
                if sent <= 0 { break }
            }
            shutdown(cfd, Int32(SHUT_RDWR))
            _ = self?.forget(cfd, ufd)
        }
        udpWriter.name = "usb-tunnel-udp2tcp"
        udpWriter.start()

        // TCP → UDP：解析 [len u32 LE][payload]
        var pending = Data()
        var header = [UInt8](repeating: 0, count: 4)
        var payload = [UInt8](repeating: 0, count: 65536)
        outer: while true {
            var got = 0
            while got < 4 {
                // 部分读必须接着 header[got] 写：从 0 重写会把帧长读坏 → 连接被误判关闭
                let n = header.withUnsafeMutableBytes {
                    recv(cfd, $0.baseAddress!.advanced(by: got), 4 - got, 0)
                }
                if n <= 0 { break outer }
                got += n
            }
            let len = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
            if len == 0 || len > 65536 { break }
            var remain = Int(len)
            while remain > 0 {
                let n = recv(cfd, &payload, min(remain, payload.count), 0)
                if n <= 0 { break outer }
                pending.append(contentsOf: payload[0..<n])
                remain -= n
            }
            _ = pending.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) {
                    sendto(ufd, raw.baseAddress, pending.count, 0,
                           UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            pending.removeAll(keepingCapacity: true)
        }
        shutdown(cfd, Int32(SHUT_RDWR))
        shutdown(ufd, Int32(SHUT_RDWR))
    }

    private func forget(_ cfd: Int32, _ ufd: Int32) {
        lock.lock(); connFds.remove(cfd); lock.unlock()
        close(ufd)
        close(cfd)
    }

    // MARK: adb reverse 轮询

    /// 无设备时退避：每 12 拍才真正跑一次（5s→60s）。adb devices 是一次进程 fork，
    /// 闲时近零成本。SLA 不依赖轮询及时性：reverse 未注册时平板探测被立即拒绝 →
    /// 秒降 WiFi 出画面（≤3s 达标），reverse 由闲时轮询补上后 30s 内自动升 USB。
    /// （NSWorkspace 无 USB 设备通知，IOKit 监听过重，不做事件驱动。）
    private var pollSkip = 0

    private func startPolling() {
        guard adbAvailable else {
            NSLog("[hyperdisplay] USB tunnel: 未找到 adb（装 platform-tools 或放 PATH），USB 有线模式不可用")
            return
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.deviceCount == 0 {
                self.pollSkip += 1
                if self.pollSkip < 12 { return }
                self.pollSkip = 0
            }
            DispatchQueue.global(qos: .utility).async { self.registerReverse() }
        }
        DispatchQueue.global(qos: .utility).async { self.registerReverse() }
    }

    /// reverse 注册核对：不能只看 serial 集合——设备重枚举、WiFi-adb 掉线都会
    /// 清空已注册的 reverse 而 serial 不变（2026-08-25 无局域网实测：禁 WiFi 后
    /// reverse 悄悄消失，"serial 在场就跳过"的旧优化导致永不重注册 → 平板探测
    /// 永远失败）。每轮用 `reverse --list` 核对，缺失才注册；有设备时 5s 一次的
    /// 小额 fork 可接受（无设备时 60s 退避不变，AGENTS §7.1）。
    private func registerReverse() {
        guard let adbPath = Self.locateAdb() else { return }
        guard let serials = Self.onlineDeviceSerials(adbPath: adbPath) else { return }
        for sn in serials {
            let installed = (Self.run(adbPath: adbPath, args: ["-s", sn, "reverse", "--list"]) ?? "")
                .contains("tcp:\(Self.tcpPort)")
            if !installed {
                _ = Self.run(adbPath: adbPath,
                             args: ["-s", sn, "reverse", "tcp:\(Self.tcpPort)", "tcp:\(Self.tcpPort)"])
                NSLog("[hyperdisplay] USB tunnel: re-registered reverse for %@", sn)
            }
        }
        if serials.count != deviceCount {
            deviceCount = serials.count
            DispatchQueue.main.async { [weak self] in self?.onDeviceCountChange?() }
        }
    }

    // MARK: adb 定位与执行

    private static func locateAdb() -> String? {
        let candidates = [
            String(format: "%@/Library/Android/sdk/platform-tools/adb", NSHomeDirectory()),
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "adb"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty { return out }
            }
        } catch {}
        return nil
    }

    private static func run(adbPath: String, args: [String]) -> String? {
        guard !adbPath.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func onlineDeviceSerials(adbPath: String) -> [String]? {
        run(adbPath: adbPath, args: ["devices"])?
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                return String(parts[0])
            }
    }
}
