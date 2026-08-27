import XCTest
@testable import Hyperdisplay

/// 布局几何与档位换算（逐条对照安卓 regionSizes/DisplayResolution 语义）
final class LayoutTests: XCTestCase {

    // 画布 2360x1640（iPad Air 类）
    private let sw = 2360
    private let sh = 1640

    private func sizes(_ cfg: LayoutConfig) -> [(Int, Int)] {
        LayoutGeometry.regionSizes(config: cfg, screenW: sw, screenH: sh)
    }

    func testDisplayResolutionNormalizeAndPresets() {
        XCTAssertEqual(DisplayResolution.normalize(999), DisplayResolution.native)
        XCTAssertEqual(DisplayResolution.normalize(1920), 1920)
        XCTAssertEqual(DisplayResolution.presetId(0), 0)
        XCTAssertEqual(DisplayResolution.presetId(1440), 1)
        XCTAssertEqual(DisplayResolution.presetId(1600), 2)
        XCTAssertEqual(DisplayResolution.presetId(1920), 3)
        XCTAssertEqual(DisplayResolution.presetId(2240), 4)
        XCTAssertEqual(DisplayResolution.label(0), "原生")
        XCTAssertEqual(DisplayResolution.label(1920), "标准")
    }

    func testHostAlignedFollows16pxRule() {
        XCTAssertEqual(DisplayResolution.hostAligned(1064, 1080).0, 1072)
        XCTAssertEqual(DisplayResolution.hostAligned(1064, 1080).1, 1088)
        // 宽下限 640、高下限 480（对照 DisplayResolution.hostAligned）
        XCTAssertEqual(DisplayResolution.hostAligned(100, 100).0, 640)
        XCTAssertEqual(DisplayResolution.hostAligned(100, 100).1, 480)
    }

    func testScaleKeepsNativeAndScalesLongEdge() {
        // 原生档：原样返回
        let native = DisplayResolution.scale(1180, 820, deviceCanvasLongEdge: 2360, longEdge: 0)
        XCTAssertEqual(native.0, 1180)
        XCTAssertEqual(native.1, 820)
        // 1920 档：长边 2360→1920，短边等比 1334.2 → 向上对齐 16px → 1344
        let scaled = DisplayResolution.scale(2360, 1640, deviceCanvasLongEdge: 2360, longEdge: 1920)
        XCTAssertEqual(scaled.0, 1920)
        XCTAssertEqual(scaled.1 % 16, 0)
        XCTAssertEqual(scaled.1, 1344)
    }

    func testRegionSizesSplitLR() {
        var cfg = LayoutConfig.default
        cfg.kind = .splitLR
        cfg.fraction = 0.5
        let r = sizes(cfg)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].0, 1180) // 2360*0.5
        XCTAssertEqual(r[0].1, 1640)
        XCTAssertEqual(r[1].0, 1180)
        XCTAssertEqual(r[1].1, 1640)
    }

    func testRegionSizesSplitTBClampsToSpec() {
        var cfg = LayoutConfig.default
        cfg.kind = .splitTB
        cfg.fraction = 0.9 // clamp 到 0.8
        let r = sizes(cfg)
        XCTAssertEqual(r[0].0, 2360)
        XCTAssertEqual(r[0].1, 1312) // 1640*0.8 = 1312
        XCTAssertEqual(r[1].1, 328)
    }

    func testRegionSizesSide() {
        var cfg = LayoutConfig.default
        cfg.kind = .side
        cfg.fraction = 0.3
        let r = sizes(cfg)
        XCTAssertEqual(r[0].0, 1652) // 主屏 2360-708
        XCTAssertEqual(r[1].0, 708)  // 侧边 2360*0.3
    }

    func testRegionSizesPipDefaultsAndCustom() {
        var cfg = LayoutConfig.default
        cfg.kind = .pip
        cfg.fraction = 0.4
        let r = sizes(cfg)
        XCTAssertEqual(r[0].0, sw)
        XCTAssertEqual(r[0].1, sh)
        XCTAssertEqual(r[1].1, 656)  // 1640*0.4
        XCTAssertEqual(r[1].0, 1048) // 656*16/10 = 1049.6 → 1049 → even → 1048

        // 手指自由缩放值直接采用并被夹取到 3/4 屏
        cfg.pipCustomW = 999_999
        cfg.pipCustomH = 999_999
        let custom = sizes(cfg)
        XCTAssertEqual(custom[1].0, even(screenW3q()))
        XCTAssertEqual(custom[1].1, even(screenH3q()))
    }

    private func screenW3q() -> Int { sw * 3 / 4 }
    private func screenH3q() -> Int { sh * 3 / 4 }
    private func even(_ v: Int) -> Int { (v / 2) * 2 }

    func testRequestedSpecsScalesByLongEdge() {
        var cfg = LayoutConfig.default
        cfg.kind = .single
        cfg.displayLongEdge = 1920
        let specs = LayoutGeometry.requestedSpecs(config: cfg, screenW: sw, screenH: sh)
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(Int(specs[0].width), 1920)
        // 短边等比 16px 对齐
        XCTAssertEqual(Int(specs[0].height) % 16, 0)
    }

    func testSeedJSONDecodesSplit() throws {
        // 模拟 defaults CLI 写入的种子形态（字符串 JSON）
        let json = "{\"kind\":1,\"fraction\":0.5,\"sideLeft\":false,\"pipRatio\":\"16:10\"," +
            "\"pipCustomW\":0,\"pipCustomH\":0,\"displayLongEdge\":0,\"clarity\":0}"
        let cfg = try JSONDecoder().decode(LayoutConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.kind, .splitLR)
        XCTAssertEqual(cfg.fraction, 0.5, accuracy: 0.001)
        // 宽松形态：缺字段也能解
        let loose = try JSONDecoder().decode(LayoutConfig.self, from: Data("{\"kind\":4}".utf8))
        XCTAssertEqual(loose.kind, .pip)
    }

    func testWireLayoutRoundTrip() {
        var cfg = LayoutConfig.default
        cfg.kind = .side
        cfg.fraction = 0.35
        cfg.sideLeft = true
        cfg.displayLongEdge = 1600
        cfg.clarity = 1
        let wire = LayoutGeometry.wireLayout(config: cfg, pipLeft: 30, pipTop: 40, transaction: 9)
        XCTAssertEqual(wire.kind, 3)
        XCTAssertEqual(wire.fractionPermille, 3500)
        XCTAssertEqual(wire.sideLeft, true)
        XCTAssertEqual(wire.displaySizePreset, 2)
        XCTAssertEqual(wire.clarity, 1)
        XCTAssertEqual(wire.transaction, 9)

        let back = LayoutGeometry.config(fromWire: wire)
        XCTAssertEqual(back.kind, .side)
        XCTAssertEqual(back.fraction, 0.35, accuracy: 0.001)
        XCTAssertEqual(back.sideLeft, true)
        XCTAssertEqual(back.displayLongEdge, 1600)
        XCTAssertEqual(back.clarity, 1)
    }
}
