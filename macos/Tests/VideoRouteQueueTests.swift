import Foundation

@main
struct VideoRouteQueueTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var queue = VideoRouteQueue<String, Int>()
        queue.append(101, to: "tablet-usb")
        queue.append(102, to: "tablet-usb")
        queue.append(201, to: "phone-wifi")

        // 手机队列可先被发送，不能再排在平板的整帧之后；同一路由仍必须 FIFO。
        check(queue.popFirst(from: "phone-wifi") == 201, "independent route must not wait behind tablet")
        check(queue.popFirst(from: "tablet-usb") == 101, "tablet FIFO first frame")
        check(queue.popFirst(from: "tablet-usb") == 102, "tablet FIFO second frame")
        check(queue.maxCount { $0 >= 100 } == 0, "queues must drain cleanly")
        print("Video route queue tests passed")
    }
}
