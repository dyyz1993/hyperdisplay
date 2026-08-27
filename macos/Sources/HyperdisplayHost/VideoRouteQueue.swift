import Foundation

/// 每个接收端各自维持 FIFO：同一路由内保持 H.264/HEVC 参考帧顺序，路由之间则
/// 不得互相等待。否则一台 Wi-Fi 客户端的分片节流会把 USB 客户端的实时帧也拖入
/// 队头阻塞。
struct VideoRouteQueue<Route: Hashable, Frame> {
    private var frames: [Route: [Frame]] = [:]

    mutating func append(_ frame: Frame, to route: Route) {
        frames[route, default: []].append(frame)
    }

    mutating func popFirst(from route: Route) -> Frame? {
        guard var queue = frames[route], !queue.isEmpty else { return nil }
        let frame = queue.removeFirst()
        if queue.isEmpty {
            frames.removeValue(forKey: route)
        } else {
            frames[route] = queue
        }
        return frame
    }

    func maxCount(where predicate: (Frame) -> Bool) -> Int {
        frames.values.map { queue in queue.reduce(into: 0) { count, frame in
            if predicate(frame) { count += 1 }
        }}.max() ?? 0
    }
}
