import Foundation
import AppKit
import CoreGraphics
import HyperdisplayObjC

/// 显示器健康监控（AGENTS §4.1 churn 卫生的运行时哨兵）：
/// 1. **ColorSync 三级监控**：
///   - 红色中毒：>50% 连续 3 采样（90s）→ 告警 + 处置预案（注销，勿反复 kill）
///   - 黄色预警：>8% 持续 10 分钟 → 提示「建销余波/温和残留，建议今日收工时注销」。
///     红色判据抓不到这个区间（实测中毒后余波可长期停在 10-20%，零日志无功能影响，
///     但不归零）——黄色档让「不正常但能忍」可见、可决策，而不是静默。
///   - 痊愈：<1% → 解除告警/预警
/// 2. **孤儿屏检测**：windowserver 挂着我们的 EDID（vendor 0x1A2B）但 host 内部无
///   对应流（崩溃/竞态泄漏）→ 连续两个采样都在才回收（避免误杀建屏竞态中的屏）。
/// 3. **churn 预算**：滑动窗口统计建屏次数，1 小时最多 20 次；达到预算后硬拒绝
///   后续建屏。时间戳写入 UserDefaults，重启 host 也不能绕过（重连风暴/误回收信号，
///   4.1.2「host 重启保持个位数」的运行时版本）。
/// 采样跑主线程 Timer（30s），进程外只起一个 `ps`，开销可忽略。
final class DisplayHealthMonitor {
    struct ColorSyncLoad {
        let displayServices: Double?
        let daemon: Double?
        let userAgent: Double?

        var peak: Double? {
            [displayServices, daemon, userAgent].compactMap { $0 }.max()
        }

        var description: String {
            let display = displayServices.map { String(format: "displayservices=%.1f%%", $0) } ?? "displayservices=未知"
            let daemon = daemon.map { String(format: "colorsyncd=%.1f%%", $0) } ?? "colorsyncd=未知"
            let agent = userAgent.map { String(format: "useragent=%.1f%%", $0) } ?? "useragent=未知"
            return "\(display), \(daemon), \(agent)"
        }
    }

    static let vendorId: UInt32 = 0x1A2B   // 与 VirtualDisplayShim 的 EDID vendor 恒定一致
    private static let hotThreshold: Double = 50.0
    private static let hotStreakLimit = 3
    private static let warmThreshold: Double = 8.0
    private static let warmDurationLimit: TimeInterval = 600 // 10 分钟
    private static let creationBudgetPerHour = 20
    private static let creationLedgerKey = "displayHealth.creationTimestamps"

    enum ColorSyncLevel { case normal, warm, hot }

    private var timer: Timer?
    private var hotStreak = 0
    private var warmSince: Date?
    private var creations: [Date] = {
        let values = UserDefaults.standard.array(forKey: creationLedgerKey) as? [Double] ?? []
        let cutoff = Date().addingTimeInterval(-3600)
        return values.map { Date(timeIntervalSince1970: $0) }.filter { $0 >= cutoff }
    }()
    private var creationBudgetAlertActive = false
    private var lastOrphans: [CGDirectDisplayID] = []
    /// 取两条 ColorSync 系统路径的最大值作为健康判据；只看 displayservices 会漏掉
    /// colorsyncd 单独高负载的真实中毒/重建余波。
    /// 两进程峰值，供所有建屏护栏使用。
    private(set) var lastColorSyncCPU: Double?
    private(set) var lastColorSyncDisplayServicesCPU: Double?
    private(set) var lastColorSyncDaemonCPU: Double?
    private(set) var lastColorSyncUserAgentCPU: Double?
    private(set) var colorSyncAlertActive = false
    private(set) var colorSyncWarmActive = false

    var level: ColorSyncLevel {
        // 建屏硬门槛看当前采样，不等待 3 次告警确认。告警需要防瞬时尖峰，
        // 但 CGVirtualDisplay 创建在已达 50% 时必须立即拒绝，避免继续加重中毒。
        if colorSyncAlertActive || (lastColorSyncCPU ?? 0) > Self.hotThreshold { return .hot }
        if colorSyncWarmActive { return .warm }
        return .normal
    }

    /// host 注入：当前合法 display id 集合（streams keys，主线程读）
    var expectedDisplayIds: () -> Set<CGDirectDisplayID> = { [] }
    /// 孤儿屏处置（默认只告警；host 覆盖为实际回收）
    var onOrphanDisplays: (([CGDirectDisplayID]) -> Void)?
    var onAlert: ((String) -> Void)?

    func start() {
        sample() // 启动即采一次，验证采样链路（ps/Timer 任一故障可立刻从日志发现）
        if let cpu = lastColorSyncCPU {
            NSLog("[hyperdisplay] display health: first sample peak ColorSync=%.1f%% (displayservices=%.1f%% colorsyncd=%.1f%% useragent=%.1f%%)",
                  cpu, lastColorSyncDisplayServicesCPU ?? 0, lastColorSyncDaemonCPU ?? 0,
                  lastColorSyncUserAgentCPU ?? 0)
        } else {
            NSLog("[hyperdisplay] display health: colorsync sample returned nil (ps parse fail?)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    // MARK: churn 预算

    /// 在调用 CGVirtualDisplay 之前检查。达到预算后宁可本次连接失败，也不能继续
    /// 制造 display churn；预算持久化，防止“重启 host → 计数归零 → 继续投毒”。
    func mayCreateDisplay() -> Bool {
        pruneCreations()
        guard creations.count < Self.creationBudgetPerHour else {
            if !creationBudgetAlertActive {
                creationBudgetAlertActive = true
                onAlert?("已阻止继续建屏：近 1 小时已创建 \(creations.count) 次（上限 \(Self.creationBudgetPerHour)）。这通常表示重连风暴；请先停止反复插拔/重启，等待预算窗口恢复。")
            }
            return false
        }
        creationBudgetAlertActive = false
        return true
    }

    func recordCreation() {
        let now = Date()
        pruneCreations(now: now)
        creations.append(now)
        persistCreations()
        if creations.count >= Self.creationBudgetPerHour {
            creationBudgetAlertActive = true
            onAlert?("建屏 churn 已达到硬上限：近 1 小时 \(creations.count) 次。后续建屏将被阻止，直到最早记录退出 1 小时窗口。")
        }
    }

    private func pruneCreations(now: Date = Date()) {
        let oldCount = creations.count
        creations.removeAll { now.timeIntervalSince($0) > 3600 }
        if creations.count != oldCount { persistCreations() }
        if creations.count < Self.creationBudgetPerHour { creationBudgetAlertActive = false }
    }

    private func persistCreations() {
        UserDefaults.standard.set(creations.map(\.timeIntervalSince1970),
                                  forKey: Self.creationLedgerKey)
    }

    // MARK: 采样

    func sample() {
        sampleColorSync()
        sampleOrphans()
    }

    private func sampleColorSync() {
        let load = Self.colorSyncLoad()
        guard let cpu = load.peak else { return }
        lastColorSyncCPU = cpu
        lastColorSyncDisplayServicesCPU = load.displayServices
        lastColorSyncDaemonCPU = load.daemon
        lastColorSyncUserAgentCPU = load.userAgent
        let now = Date()
        if cpu > Self.hotThreshold {
            warmSince = nil
            colorSyncWarmActive = false
            hotStreak += 1
            if hotStreak >= Self.hotStreakLimit && !colorSyncAlertActive {
                colorSyncAlertActive = true
                onAlert?(String(
                    format: "ColorSync 中毒：%@（峰值 %d%%）持续高负载。按预案处置（AGENTS 4.1.6）：注销会话，未愈则重启；杀该进程无效，勿反复尝试。痊愈判据三个进程均 <1%%。",
                    load.description, Int(cpu)))
            }
        } else if cpu > Self.warmThreshold {
            hotStreak = 0
            // 黄色档：>8% 持续 10 分钟才算（短暂余波正常，不骚扰）
            if colorSyncAlertActive { return } // 红色未解除期间不降级打横幅
            if warmSince == nil { warmSince = now }
            if !colorSyncWarmActive,
               let since = warmSince, now.timeIntervalSince(since) > Self.warmDurationLimit {
                colorSyncWarmActive = true
                onAlert?(String(
                    format: "ColorSync 温和残留：%@（峰值 %.0f%%）已持续 10 分钟（无功能影响但未归零，疑似建销余波）。建议今日收工时注销一次清零；若升到 50%% 会转为中毒告警。",
                    load.description, cpu))
            }
        } else {
            hotStreak = 0
            warmSince = nil
            if colorSyncAlertActive && cpu < 1.0 {
                colorSyncAlertActive = false
                onAlert?(String(format: "ColorSync 已痊愈（CPU %.1f%%）", cpu))
            }
            if colorSyncWarmActive && cpu < Self.warmThreshold {
                colorSyncWarmActive = false
                onAlert?(String(format: "ColorSync 残留已消退（CPU %.1f%%）", cpu))
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

    /// ColorSync 至少有三条可能单独打满的系统路径。创建屏前/创建后哨兵统一看峰值，
    /// 不能再把 `colorsync.displayservices` 的低值误解为系统已经恢复。
    static func colorSyncLoad() -> ColorSyncLoad {
        ColorSyncLoad(
            displayServices: processCPU(named: "colorsync.displayservices"),
            daemon: processCPU(named: "colorsyncd"),
            userAgent: processCPU(named: "colorsync.useragent"))
    }
}
