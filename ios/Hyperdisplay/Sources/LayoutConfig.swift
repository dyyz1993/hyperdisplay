import Foundation
import os.log

private let layoutLog = Logger(subsystem: "com.hyperdisplay.session", category: "layout")

// MARK: - 布局模型（对照 MainActivity.LayoutKind/LayoutConfig + DisplayResolution.kt）

/// ordinal 即线上 kind 字节（writeTo clamp 0...4）
enum LayoutKind: Int, CaseIterable, Codable {
    case single = 0
    case splitLR = 1
    case splitTB = 2
    case side = 3
    case pip = 4

    var label: String {
        switch self {
        case .single: return "单屏全屏"
        case .splitLR: return "左右分屏"
        case .splitTB: return "上下分屏"
        case .side: return "主屏+侧边"
        case .pip: return "画中画"
        }
    }
}

/// 画中画宽高比；wire 值与安卓 ratioOf/when 映射一致（16:10=0, 3:2=1, 4:3=2, 1:1=3）
enum PipRatio: String, CaseIterable, Codable {
    case r1610 = "16:10"
    case r32 = "3:2"
    case r43 = "4:3"
    case r11 = "1:1"

    var wireValue: UInt8 {
        switch self {
        case .r1610: return 0
        case .r32: return 1
        case .r43: return 2
        case .r11: return 3
        }
    }

    var parts: (Int, Int) {
        switch self {
        case .r1610: return (16, 10)
        case .r32: return (3, 2)
        case .r43: return (4, 3)
        case .r11: return (1, 1)
        }
    }

    static func from(wire: UInt8) -> PipRatio {
        PipRatio.allCases.first { $0.wireValue == wire } ?? .r1610
    }
}

struct LayoutConfig: Equatable, Codable {
    var kind: LayoutKind = .single
    /// 分割位置/侧边占比/画中画高度占比（线上为千分比 fraction*10000，2000..8000）
    var fraction: Float = 0.5
    var sideLeft: Bool = false
    var pipRatio: PipRatio = .r1610
    /// 手指自由缩放后的画中画尺寸（0=按比例默认）
    var pipCustomW: Int = 0
    var pipCustomH: Int = 0
    /// 0=本机原生尺寸；其余为虚拟屏长边档位
    var displayLongEdge: Int = 0
    /// 0=明确标准 1x；1=严格请求实际 Retina 2x
    var clarity: Int = 0

    static let `default` = LayoutConfig()

    // 定义了 init(from:) 后 Swift 不再合成无参构造，这里补回
    init() {}

    // 种子 JSON 可能由 defaults CLI 或旧版本写入，缺字段必须回落默认值而不是
    // 整份拒绝（testSeedJSONDecodesSplit 固化此语义）；合成 Codable 做不到。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(LayoutKind.self, forKey: .kind) ?? .single
        fraction = try c.decodeIfPresent(Float.self, forKey: .fraction) ?? 0.5
        sideLeft = try c.decodeIfPresent(Bool.self, forKey: .sideLeft) ?? false
        pipRatio = try c.decodeIfPresent(PipRatio.self, forKey: .pipRatio) ?? .r1610
        pipCustomW = try c.decodeIfPresent(Int.self, forKey: .pipCustomW) ?? 0
        pipCustomH = try c.decodeIfPresent(Int.self, forKey: .pipCustomH) ?? 0
        displayLongEdge = try c.decodeIfPresent(Int.self, forKey: .displayLongEdge) ?? 0
        clarity = try c.decodeIfPresent(Int.self, forKey: .clarity) ?? 0
    }
}

/// 副屏像素档位（对照 DisplayResolution.kt）。0 表示按本机当前原生画布请求。
enum DisplayResolution {
    static let native = 0
    static let supportedLongEdges: Set<Int> = [native, 1440, 1600, 1920, 2240]

    static func normalize(_ longEdge: Int) -> Int {
        supportedLongEdges.contains(longEdge) ? longEdge : native
    }

    /// 只用于跨端展示/恢复，不影响已有像素档位兼容值
    static func presetId(_ longEdge: Int) -> UInt8 {
        switch normalize(longEdge) {
        case native: return 0
        case 1440: return 1
        case 1600: return 2
        case 1920: return 3
        default: return 4
        }
    }

    static func presetLongEdge(_ id: UInt8) -> Int {
        switch id {
        case 1: return 1440
        case 2: return 1600
        case 3: return 1920
        case 4: return 2240
        default: return native
        }
    }

    static func label(_ longEdge: Int) -> String {
        switch normalize(longEdge) {
        case native: return "原生"
        case 1440: return "特大"
        case 1600: return "大"
        case 1920: return "标准"
        default: return "紧凑"
        }
    }

    /// 归一成横屏画布
    static func landscapeCanvas(_ width: Int, _ height: Int) -> (Int, Int) {
        (max(width, height), min(width, height))
    }

    /// Host 创建 CGVirtualDisplay 前的统一 16px 对齐规则
    static func hostAligned(_ width: Int, _ height: Int) -> (Int, Int) {
        func aligned(_ value: Int, _ minimum: Int) -> Int {
            max((value + 15) & ~15, minimum)
        }
        return (aligned(width, 640), aligned(height, 480))
    }

    static func scale(_ width: Int, _ height: Int, deviceCanvasLongEdge: Int, longEdge: Int) -> (Int, Int) {
        let normalized = normalize(longEdge)
        if normalized == native { return (width, height) }
        let source = max(deviceCanvasLongEdge, 1)
        let scale = Float(normalized) / Float(source)
        func aligned(_ value: Int) -> Int { max((Int(Float(value) * scale) + 15) & ~15, 640) }
        return (aligned(width), aligned(height))
    }
}

// MARK: - 区域几何（对照 regionSizes/evenOf/pip 辅助；像素域，与本地排版无关）

enum LayoutGeometry {

    static func even(_ v: Int) -> Int { (v / 2) * 2 }

    /// 画中画最小边：约大屏短边的 1/10，下限 160px
    static func pipMinSide(screenW: Int, screenH: Int) -> Int {
        max(160, min(screenW, screenH) / 10)
    }

    static func pipDefaultH(config: LayoutConfig, screenH: Int) -> Int {
        even(min(max(Int(Float(screenH) * config.fraction), screenH / 4), screenH / 2))
    }

    static func pipDefaultW(config: LayoutConfig, screenH: Int) -> Int {
        let (rn, rd) = config.pipRatio.parts
        return even(pipDefaultH(config: config, screenH: screenH) * rn / rd)
    }

    /// 布局 → 各区域虚拟屏像素尺寸（顺序即订阅顺序，第一个是主屏）
    /// SINGLE 返回空（调用方回落到整机画布单屏）
    static func regionSizes(config: LayoutConfig, screenW: Int, screenH: Int) -> [(Int, Int)] {
        let f = min(max(config.fraction, 0.2), 0.8)
        switch config.kind {
        case .single:
            return []
        case .splitLR:
            let lw = even(min(max(Int(Float(screenW) * f), screenW / 5), screenW * 4 / 5))
            return [(lw, screenH), (even(screenW - lw), screenH)]
        case .splitTB:
            let th = even(min(max(Int(Float(screenH) * f), screenH / 5), screenH * 4 / 5))
            return [(screenW, th), (screenW, even(screenH - th))]
        case .side:
            let sideW = even(min(max(Int(Float(screenW) * f), screenW / 5), screenW * 2 / 5))
            return [(even(screenW - sideW), screenH), (sideW, screenH)]
        case .pip:
            let minSide = pipMinSide(screenW: screenW, screenH: screenH)
            if config.pipCustomW > 0 && config.pipCustomH > 0 {
                // 手指自由缩放过的尺寸：直接采用（夹在最小边与 3/4 屏之间）
                let w = even(min(max(config.pipCustomW, minSide), screenW * 3 / 4))
                let h = even(min(max(config.pipCustomH, minSide), screenH * 3 / 4))
                return [(screenW, screenH), (w, h)]
            }
            let (rn, rd) = config.pipRatio.parts
            let ph = even(min(max(Int(Float(screenH) * f), screenH / 4), screenH / 2))
            return [(screenW, screenH), (even(ph * rn / rd), ph)]
        }
    }

    /// HELLO 的目标屏规格（对照 requestedDisplaySpecs）：
    /// 单屏=当前画布；其余=regionSizes；再按显示大小档位等比缩放。
    static func requestedSpecs(config: LayoutConfig, screenW: Int, screenH: Int) -> [RequestedDisplaySpec] {
        let (longW, _) = DisplayResolution.landscapeCanvas(screenW, screenH)
        let raw: [(Int, Int)]
        if config.kind == .single, regionSizes(config: config, screenW: screenW, screenH: screenH).isEmpty {
            raw = [(screenW, screenH)]
        } else {
            raw = regionSizes(config: config, screenW: screenW, screenH: screenH)
        }
        let specs = raw.ifEmpty([(screenW, screenH)]).prefix(4)
        return specs.map { w, h -> RequestedDisplaySpec in
            let scaled = DisplayResolution.scale(w, h, deviceCanvasLongEdge: longW,
                                                 longEdge: config.displayLongEdge)
            return RequestedDisplaySpec(width: UInt16(clamping: scaled.0),
                                        height: UInt16(clamping: scaled.1))
        }
    }

    /// HELLO 布局快照（对照 layoutStateForHost）
    static func wireLayout(config: LayoutConfig, pipLeft: Int16, pipTop: Int16,
                           transaction: UInt32 = 0) -> LayoutWire {
        var wire = LayoutWire()
        wire.kind = UInt8(config.kind.rawValue)
        wire.fractionPermille = UInt16(clamping: Int(config.fraction * 10_000))
        wire.sideLeft = config.sideLeft
        wire.pipRatio = config.pipRatio.wireValue
        wire.pipCustomW = UInt16(clamping: config.pipCustomW)
        wire.pipCustomH = UInt16(clamping: config.pipCustomH)
        wire.displayLongEdge = UInt16(clamping: DisplayResolution.normalize(config.displayLongEdge))
        wire.pipLeft = pipLeft
        wire.pipTop = pipTop
        wire.displaySizePreset = DisplayResolution.presetId(config.displayLongEdge)
        wire.clarity = UInt8(clamping: config.clarity)
        wire.transaction = transaction
        return wire
    }

    /// savedLayout 恢复（对照 restoreLayoutFromHost）
    static func config(fromWire wire: LayoutWire) -> LayoutConfig {
        var cfg = LayoutConfig()
        cfg.kind = LayoutKind(rawValue: Int(wire.kind)) ?? .single
        cfg.fraction = min(max(Float(wire.fractionPermille) / 10_000, 0.2), 0.8)
        cfg.sideLeft = wire.sideLeft
        cfg.pipRatio = PipRatio.from(wire: wire.pipRatio)
        cfg.pipCustomW = Int(wire.pipCustomW)
        cfg.pipCustomH = Int(wire.pipCustomH)
        cfg.displayLongEdge = DisplayResolution.normalize(Int(wire.displayLongEdge))
        cfg.clarity = Int(wire.clarity.coerceIn(0...1))
        return cfg
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

// MARK: - 持久化

extension LayoutConfig {
    private static let storeKey = "hd.layoutConfig"
    private static let pipLeftKey = "hd.layout.pipLeft"
    private static let pipTopKey = "hd.layout.pipTop"

    static func load() -> LayoutConfig {
        let defaults = UserDefaults.standard
        // 兼容两种写入形态：原生 Data（app 内保存）与 CLI `defaults write -string` 的 JSON 字符串
        var data = defaults.data(forKey: storeKey) ?? Data()
        var source = "data"
        if data.isEmpty, let raw = defaults.string(forKey: storeKey) {
            data = Data(raw.utf8)
            source = "string"
        }
        if let cfg = try? JSONDecoder().decode(LayoutConfig.self, from: data) {
            var fixed = cfg
            fixed.fraction = min(max(cfg.fraction, 0.2), 0.8)
            fixed.displayLongEdge = DisplayResolution.normalize(cfg.displayLongEdge)
            fixed.clarity = min(max(cfg.clarity, 0), 1)
            layoutLog.log("layout loaded source=\(source) kind=\(fixed.kind.rawValue) fraction=\(fixed.fraction) longEdge=\(fixed.displayLongEdge) clarity=\(fixed.clarity)")
            return fixed
        }
        layoutLog.log("layout load failed (source=\(source), \(data.count)B) — default single")
        return .default
    }

    func save(pipLeft: Int, pipTop: Int) {
        let d = (try? JSONEncoder().encode(self)) ?? Data()
        UserDefaults.standard.set(d, forKey: Self.storeKey)
        UserDefaults.standard.set(pipLeft, forKey: Self.pipLeftKey)
        UserDefaults.standard.set(pipTop, forKey: Self.pipTopKey)
    }

    static func loadPipLeft() -> Int { UserDefaults.standard.integer(forKey: pipLeftKey) }
    static func loadPipTop() -> Int { UserDefaults.standard.integer(forKey: pipTopKey) }
}
