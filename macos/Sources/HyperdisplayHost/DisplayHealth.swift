import Foundation
import AppKit
import CoreGraphics
import HyperdisplayObjC

/// 显示器健康监控（AGENTS §4.1 churn 卫生的运行时哨兵）：
/// 1. **ColorSync 中毒探测**：`colorsync.displayservices` 持续高 CPU（>50% 连续 3 个
///   采样）→ 告警并引导按 4.1.6 预案处置（注销，勿反复 kill）；CPU 回落 <1% 报痊愈。
/// 2. **孤儿屏检测**：windowserver 挂着我们的 EDID（vendor 0x1A2B）但 host 内部无
///   对应流（崩溃/竞态泄漏）→ 连续两个采样都在才回收（避免误杀建屏竞态中的屏）。
/// 3. **churn 预算**：滑动窗口统计建屏次数，1 小时 >20 次告警（重连风暴/误回收信号，
///   4.1.2「host 重启保持个位数」的运行时版本）。
/// 采样跑主线程 Timer（30s），进程外只起一个 `ps`，开销可忽略。
final class DisplayHealthMonitor {
    static let vendorId: UInt32 = 0x1A2B   // 与 VirtualDisplayShim 的 EDID vendor 恒定一致
    private static let hotThreshold: Double = 50.0
    private static let hotStreakLimit = 3
    private static let creationBudgetPerHour = 20

    private var timer: Timer?
    private var hotStreak = 0
    private var creations: [Date] = []
    private var lastOrphans: [CGDirectDisplayID] = []
    private(set) var lastColorSyncCPU: Double?
    private(set) var colorSyncAlertActive = false

    /// host 注入：当前合法 display id 集合（streams keys，主线程读）
    var expectedDisplayIds: () -> Set<CGDirectDisplayID> = { [] }
    /// 孤儿屏处置（默认只告警；host 覆盖为实际回收）
    var onOrphanDisplays: (([CGDirectDisplayID]) -> Void)?
    var onAlert: ((String) -> Void)?

    func start() {
        sample() // 启动即采一次，验证采样链路（ps/Timer 任一故障可立刻从日志发现）
        if let cpu = lastColorSyncCPU {
            NSLog("[hyperdisplay] display health: first sample colorsync=%.1f%%", cpu)
        } else {
            NSLog("[hyperdisplay] display health: colorsync sample returned nil (ps parse fail?)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    // MARK: churn 预算

    func recordCreation() {
        let now = Date()
        creations.append(now)
        creations.removeAll { now.timeIntervalSince($0) > 3600 }
        if creations.count > Self.creationBudgetPerHour {
            onAlert?("churn 预算告警：近 1 小时建屏 \(creations.count) 次（预算 \(Self.creationBudgetPerHour)）——检查重连风暴/误回收/看门狗升级是否过频（AGENTS 4.1.2/4.1.5）")
        }    }

    // MARK: 采样

    func sample() {
        sampleColorSync()
        sampleOrphans()
    }

    private func sampleColorSync() {
        guard let cpu = Self.processCPU(named: "colorsync.displayservices") else { return }
        lastColorSyncCPU = cpu
        if cpu > Self.hotThreshold {
            hotStreak += 1
            if hotStreak >= Self.hotStreakLimit && !colorSyncAlertActive {
                colorSyncAlertActive = true
                onAlert?(String(
                    format: "ColorSync 中毒：colorsync.displayservices 持续 %d%% CPU。按预案处置（AGENTS 4.1.6）：注销会话，未愈则重启；杀该进程无效，勿反复尝试。痊愈判据 CPU<1%%。",
                    Int(cpu)))
            }
        } else {
            hotStreak = 0
            if colorSyncAlertActive && cpu < 1.0 {
                colorSyncAlertActive = false
                onAlert?(String(format: "ColorSync 已痊愈（CPU %.1f%%）", cpu))
            }
        }
    }

    private func sampleOrphans() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let expected = expectedDisplayIds()
        let orphans = ids.filter { CGDisplayVendorNumber($0) == Self.vendorId && !expected.contains($0) }
        // 连续两个采样周期都在的才是真孤儿（单次可能是建屏竞态）
        let confirmed = orphans.filter { lastOrphans.contains($0) }
        lastOrphans = orphans
        guard !confirmed.isEmpty else { return }
        onAlert?("检测到 \(confirmed.count) 块孤儿虚拟屏（系统挂着但无对应流）——回收: \(confirmed.map(String.init).joined(separator: ","))")
        onOrphanDisplays?(confirmed)
    }

    /// 进程 CPU 占用（%）。ps 每 30s 一次，开销可忽略。
    /// 注意必须先读完管道再 waitUntilExit：ps 输出超管道缓冲（~64KB，进程数多时
    /// 会超）时子进程写阻塞，先等退出 = 主线程死锁（2026-08-20 实测时好时坏的根因）。
    static func processCPU(named name: String) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "%cpu=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        // 先排干 stdout（读到 EOF = 子进程已写完并关闭），再收尸；stderr 同步排空
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: outData, encoding: .utf8) ?? ""
        _ = errData
        for line in out.split(separator: "\n") where line.hasSuffix(name) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = parts.first, let cpu = Double(first) { return cpu }
        }
        return nil
    }
}
