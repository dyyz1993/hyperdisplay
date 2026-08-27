import Foundation

/// 低频建屏诊断时间线。只记录连接、销毁、创建、枚举和重试等拓扑事件；空闲串流
/// 不写盘、不起定时器。文件限制在 64 KiB，便于用户反馈“打开后为什么慢”。
final class TopologyTimeline {
    static let shared = TopologyTimeline()

    private let queue = DispatchQueue(label: "com.hyperdisplay.topology-timeline", qos: .utility)
    private let url: URL
    private let maxBytes = 64 * 1024

    private init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Hyperdisplay/topology.log")
    }

    func record(_ message: String) {
        let safe = message.replacingOccurrences(of: "\n", with: " ")
        queue.async { [url, maxBytes] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date())
                let line = "\(stamp) \(safe)\n"
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                   size > maxBytes {
                    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let suffix = String(old.suffix(maxBytes / 2))
                    try suffix.write(to: url, atomically: true, encoding: .utf8)
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                } else {
                    try line.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                // 诊断不可反向影响实时会话。
            }
        }
    }
}
