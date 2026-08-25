import Foundation
import Darwin
import Darwin.Mach

/// 当前 host 的低频资源采样。只读取本进程的累计 CPU 时间和 task_info，
/// 不启动 `ps`/子进程，也不位于视频或 UDP 热路径。
final class ProcessResourceMonitor {
    struct Sample {
        let cpuPercent: Double
        let residentBytes: UInt64
    }

    private var lastSampleAt: Date?
    private var lastCPUSeconds: Double = 0
    private(set) var latest = Sample(cpuPercent: 0, residentBytes: 0)

    /// 采样间隔固定为 5 秒：足够发现持续资源回归，又不会为监控本身制造负载。
    @discardableResult
    func sampleIfDue(now: Date = Date()) -> Sample? {
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) < 5 { return nil }
        let cpuSeconds = Self.processCPUSeconds()
        defer {
            lastSampleAt = now
            lastCPUSeconds = cpuSeconds
        }
        guard let previousAt = lastSampleAt else {
            latest = Sample(cpuPercent: 0, residentBytes: Self.residentBytes())
            return latest
        }
        let wallSeconds = now.timeIntervalSince(previousAt)
        let cpuPercent = wallSeconds > 0
            ? max(0, (cpuSeconds - lastCPUSeconds) / wallSeconds * 100)
            : 0
        latest = Sample(cpuPercent: cpuPercent, residentBytes: Self.residentBytes())
        return latest
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
