import XCTest
@testable import Hyperdisplay

/// 移植 android/app/src/test/.../FrameAssemblerTest.kt，保证两端重组语义一致
final class FrameAssemblerTests: XCTestCase {

    private final class Recorder {
        var delivered: [Int64] = []
        var keyframeReasons: [String] = []
        var congestionFrames: [Int64] = []
    }

    private func makeAssembler(_ recorder: Recorder) -> FrameAssembler {
        FrameAssembler(callbacks: .init(
            onFrame: { frameId, _, _ in recorder.delivered.append(frameId) },
            onKeyframeNeeded: { reason in recorder.keyframeReasons.append(reason) },
            onNackKeyframeFragments: { frameId, _ in recorder.congestionFrames.append(frameId) },
            debugLog: { _ in }
        ))
    }

    /// 未完成的 IDR 不能被后续增量帧抢走（等 IDR 窗口内忽略非关键帧）
    func testIncompleteRecoveryKeyframeIsNotPreemptedByLaterDeltaFrame() {
        let recorder = Recorder()
        let assembler = makeAssembler(recorder)
        var now = UInt64(1_000)

        assembler.onFragment(frameId: 10, fragIdx: 0, fragCount: 2, keyframe: true,
                             payload: Data([1]), nowMs: now)
        now += 10
        assembler.onFragment(frameId: 11, fragIdx: 0, fragCount: 1, keyframe: false,
                             payload: Data([2]), nowMs: now)
        now += 10
        assembler.onFragment(frameId: 10, fragIdx: 1, fragCount: 2, keyframe: true,
                             payload: Data([3]), nowMs: now)

        XCTAssertEqual(recorder.delivered, [10])
    }

    /// 解码背压把后续依赖帧挡到下一张 IDR，同时空 NACK 反馈拥塞
    func testDecoderBackpressureDropsDependentFramesUntilNextKeyframe() {
        let recorder = Recorder()
        let assembler = makeAssembler(recorder)
        var now = UInt64(2_000)

        assembler.onFragment(frameId: 1, fragIdx: 0, fragCount: 1, keyframe: true,
                             payload: Data([1]), nowMs: now)
        now += 10
        assembler.onFragment(frameId: 2, fragIdx: 0, fragCount: 1, keyframe: false,
                             payload: Data([2]), nowMs: now)
        now += 10
        assembler.requireKeyframeAfterDecoderBackpressure(frameId: 2, nowMs: now)
        now += 10
        assembler.onFragment(frameId: 3, fragIdx: 0, fragCount: 1, keyframe: false,
                             payload: Data([3]), nowMs: now)
        now += 10
        assembler.onFragment(frameId: 4, fragIdx: 0, fragCount: 1, keyframe: true,
                             payload: Data([4]), nowMs: now)

        XCTAssertEqual(recorder.delivered, [1, 2, 4])
        XCTAssertTrue(recorder.keyframeReasons.contains { $0.contains("decoder queue full") })
        XCTAssertEqual(recorder.congestionFrames, [2])
    }

    /// 分片停滞超过 250ms 视为丢帧；等待首张 IDR 时空转也要周期性要关键帧
    func testStallCheckRequestsKeyframeWhenIdleWaiting() {
        let recorder = Recorder()
        let assembler = makeAssembler(recorder)
        var now = UInt64(3_000)

        assembler.stallCheck(nowMs: now) // 第一发（idle-wait）
        XCTAssertFalse(recorder.keyframeReasons.isEmpty)
        recorder.keyframeReasons.removeAll()

        now += 600 // 超过 500ms 限频窗口后再触发一次
        assembler.stallCheck(nowMs: now)
        XCTAssertTrue(recorder.keyframeReasons.contains { $0 == "idle-wait" })
    }

    func testResetRestoresWaitingForKeyframeState() {
        let recorder = Recorder()
        let assembler = makeAssembler(recorder)
        var now = UInt64(4_000)

        assembler.onFragment(frameId: 1, fragIdx: 0, fragCount: 1, keyframe: true,
                             payload: Data([9]), nowMs: now)
        XCTAssertEqual(recorder.delivered, [1])
        now += 10
        assembler.reset()
        now += 10
        assembler.onFragment(frameId: 2, fragIdx: 0, fragCount: 1, keyframe: false,
                             payload: Data([8]), nowMs: now)
        // 重连后没有参考帧，delta 必须被丢弃
        XCTAssertEqual(recorder.delivered, [1])
    }

    /// 回归（真机 0x8BADF00D 根因，2026-08-29）：解码背压时 onFrame 回调会在
    /// 同一线程同步重入 requireKeyframeAfterDecoderBackpressure。NSLock 不可
    /// 重入，旧实现在持锁期间直接发回调 → 主线程自死锁 → watchdog 杀进程。
    /// 本测试在 onFrame 里原样重放该重入路径；若回归为死锁，onFragment 不会
    /// 在超时内返回。
    func testOnFrameCallbackMayReenterRequireKeyframeWithoutDeadlock() {
        let recorder = Recorder()
        var assembler: FrameAssembler!
        assembler = FrameAssembler(callbacks: .init(
            onFrame: { _, _, _ in
                assembler.requireKeyframeAfterDecoderBackpressure(frameId: 1)
                recorder.delivered.append(1)
            },
            onKeyframeNeeded: { reason in recorder.keyframeReasons.append(reason) },
            onNackKeyframeFragments: { frameId, _ in recorder.congestionFrames.append(frameId) },
            debugLog: { _ in }
        ))

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            assembler.onFragment(frameId: 1, fragIdx: 0, fragCount: 1, keyframe: true,
                                 payload: Data([9]))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success,
                       "onFragment 自死锁：onFrame 回调持锁重入 requireKeyframeAfterDecoderBackpressure")
        XCTAssertEqual(recorder.delivered, [1])
    }
}
