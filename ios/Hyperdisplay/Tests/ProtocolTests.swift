import XCTest
@testable import Hyperdisplay

/// 协议编解码字节级对拍（字段偏移与 macos/Sources/HyperdisplayHost/Protocol.swift、
/// android HostSession.kt 保持一致）
final class ProtocolTests: XCTestCase {

    private func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset]) |
            (UInt32(data[data.startIndex + offset + 1]) << 8) |
            (UInt32(data[data.startIndex + offset + 2]) << 16) |
            (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    private func u64le(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return v
    }

    func testHelloLayoutMatchesWireSpec() {
        var layout = LayoutWire()
        layout.kind = 2
        layout.clarity = 1
        layout.transaction = 7
        let data = ClientWire.hello(clientWidth: 2360, clientHeight: 1640,
                                    code: 123_456, deviceId: 42,
                                    fingerprint: 0x1122334455667788,
                                    deviceName: "iPad",
                                    specs: [RequestedDisplaySpec(width: 1920, height: 1080)],
                                    layout: layout)
        XCTAssertEqual(data[0], PacketType.hello.rawValue)
        XCTAssertEqual(u32le(data, 1), 0) // seq
        let bodyStart = 5
        XCTAssertEqual(data[bodyStart], ClientWire.protoVersion)
        XCTAssertEqual(u16le(data, bodyStart + 1), 2360)
        XCTAssertEqual(u16le(data, bodyStart + 3), 1640)
        XCTAssertEqual(u32le(data, bodyStart + 5), 123_456)
        XCTAssertEqual(u32le(data, bodyStart + 9), 42)
        XCTAssertEqual(data[bodyStart + 13], 1) // specs count
        XCTAssertEqual(u16le(data, bodyStart + 14), 1920)
        XCTAssertEqual(u16le(data, bodyStart + 16), 1080)
        let fingerprintOffset = bodyStart + 18
        XCTAssertEqual(u64le(data, fingerprintOffset), 0x1122334455667788)
        let layoutOffset = fingerprintOffset + 8
        XCTAssertEqual(data[layoutOffset], 2)                        // kind
        XCTAssertEqual(u16le(data, layoutOffset + 1), 5000)          // fractionPermille
        let nameLenOffset = layoutOffset + LayoutWire.byteCount
        XCTAssertEqual(data[nameLenOffset], 4) // "iPad".utf8.count
        XCTAssertEqual(Array(data[(nameLenOffset + 1)..<(nameLenOffset + 5)]), Array("iPad".utf8))
        // D2 扩展：[D2][1][preset][clarity][transaction u32]
        let extOffset = nameLenOffset + 5
        XCTAssertEqual(data[extOffset], 0xD2)
        XCTAssertEqual(data[extOffset + 1], 1)
        XCTAssertEqual(data[extOffset + 2], 0)  // preset 原生
        XCTAssertEqual(data[extOffset + 3], 1)  // clarity Retina
        XCTAssertEqual(u32le(data, extOffset + 4), 7)
        XCTAssertEqual(data.count, extOffset + LayoutWire.extensionByteCount)
    }

    func testSavedLayoutDecodeWithExtension() {
        var body: [UInt8] = Array(wirePacket(.savedLayout))
        body.append(2)                                   // kind = SPLIT_TB
        appendLE(&body, UInt16(6000))                    // fractionPermille
        body.append(0)                                   // sideLeft
        body.append(1)                                   // pipRatio 3:2
        appendLE(&body, UInt16(800))                     // pipCustomW
        appendLE(&body, UInt16(500))                     // pipCustomH
        appendLE(&body, UInt16(1920))                    // displayLongEdge
        appendLE(&body, Int16(120))                      // pipLeft
        appendLE(&body, Int16(64))                       // pipTop
        body.append(0xD2); body.append(1); body.append(3); body.append(1) // preset 1920, clarity 1

        guard case .savedLayout(let wire)? = Optional(HostWire.parse(Data(body))) else {
            return XCTFail("savedLayout parse failed")
        }
        let cfg = LayoutGeometry.config(fromWire: wire)
        XCTAssertEqual(cfg.kind, .splitTB)
        XCTAssertEqual(cfg.fraction, 0.6, accuracy: 0.001)
        XCTAssertEqual(cfg.pipRatio, .r32)
        XCTAssertEqual(cfg.pipCustomW, 800)
        XCTAssertEqual(cfg.displayLongEdge, 1920)
        XCTAssertEqual(wire.pipLeft, 120)
        XCTAssertEqual(wire.clarity, 1)
        XCTAssertEqual(DisplayResolution.presetLongEdge(wire.displaySizePreset), 1920)
    }

    func testWelcomeRoundTrip() {
        var out: [UInt8] = Array(wirePacket(.welcome))
        appendLE(&out, UInt16(3))     // displayId
        out.append(ClientWire.protoVersion)
        out.append(1)                 // codec hevc
        appendLE(&out, UInt16(2800))  // w
        appendLE(&out, UInt16(1840))  // h
        out.append(60)                // fps
        out.append(0)                 // controlEnabled=false（纯显示）

        guard case .welcome(let displayId, let proto, let codec, let w, let h, let fps,
                            let controlEnabled) = HostWire.parse(Data(out)) else {
            return XCTFail("welcome parse failed")
        }
        XCTAssertEqual(displayId, 3)
        XCTAssertEqual(proto, ClientWire.protoVersion)
        XCTAssertEqual(codec, 1)
        XCTAssertEqual(w, 2800)
        XCTAssertEqual(h, 1840)
        XCTAssertEqual(fps, 60)
        XCTAssertFalse(controlEnabled)
    }

    func testVideoFragmentParseAndRejections() {
        var out: [UInt8] = Array(wirePacket(.videoFrag, seq: 77))
        appendLE(&out, UInt16(5))      // displayId
        appendLE(&out, UInt16(0))      // fragIdx
        appendLE(&out, UInt16(2))      // fragCount
        out.append(1)                  // flags=keyframe
        out.append(contentsOf: [0xAB, 0xCD])

        guard case .videoFragment(let displayId, let frameId, let idx, let count,
                                  let keyframe, let payload) = HostWire.parse(Data(out)) else {
            return XCTFail("fragment parse failed")
        }
        XCTAssertEqual(displayId, 5)
        XCTAssertEqual(frameId, 77)
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(keyframe)
        XCTAssertEqual(payload, Data([0xAB, 0xCD]))

        // idx >= count → 拒绝
        out[5 + 2] = 2
        if case .some(.videoFragment) = HostWire.parse(Data(out)) {
            XCTFail("idx>=count should be rejected")
        }
    }

    func testNackBytesMatchHostExpectation() {
        let data = ClientWire.nack(displayId: 9, frameId: 1000, indices: [0, 2])
        XCTAssertEqual(data[0], PacketType.nack.rawValue)
        XCTAssertEqual(u32le(data, 1), 0)
        XCTAssertEqual(u16le(data, 5), 9)
        XCTAssertEqual(u32le(data, 7), 1000)
        XCTAssertEqual(u16le(data, 11), 2)
        XCTAssertEqual(u16le(data, 13), 0)
        XCTAssertEqual(u16le(data, 15), 2)
        XCTAssertEqual(data.count, 17)
    }

    func testPongKnownFlagSemantics() {
        let bare = wirePacket(.pong, seq: 5) // 老 host 无尾字节 → known
        guard case .pong(let knownBare) = HostWire.parse(bare)! else { return XCTFail() }
        XCTAssertTrue(knownBare)

        var unknownOut: [UInt8] = Array(bare)
        unknownOut.append(0)
        guard case .pong(let knownUnknown) = HostWire.parse(Data(unknownOut))! else { return XCTFail() }
        XCTAssertFalse(knownUnknown)
    }

    func testDisplaysListParse() {
        var out: [UInt8] = Array(wirePacket(.displays))
        out.append(2) // count
        for (id, name) in [(UInt32(11), "A"), (UInt32(22), "BB")] {
            appendLE(&out, id)
            appendLE(&out, UInt16(1400))
            appendLE(&out, UInt16(920))
            let bytes = Array(name.utf8)
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        guard case .displays(let list)? = Optional(HostWire.parse(Data(out))) else {
            return XCTFail("displays parse failed")
        }
        XCTAssertEqual(list, [
            DisplayInfo(id: 11, width: 1400, height: 920, name: "A"),
            DisplayInfo(id: 22, width: 1400, height: 920, name: "BB"),
        ])
    }

    func testAnnexBSplittingAndAvccConversion() {
        // 4 字节起始码 + 尾部零归下一个前导零的场景都要正确切分
        var stream: [UInt8] = []
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x40, 0x01]) // VPS
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x42, 0x01])       // SPS (3字节码)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x44, 0x01]) // PPS
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x26, 0xFF])       // slice

        let nals = AnnexB.nals(in: Data(stream))
        XCTAssertEqual(nals.count, 4)
        XCTAssertEqual(nals[0], [0x40, 0x01])
        XCTAssertEqual(nals[1], [0x42, 0x01])
        XCTAssertEqual(nals[2], [0x44, 0x01])
        XCTAssertEqual(nals[3], [0x26, 0xFF])

        let avcc = AnnexB.avccData(from: nals)
        XCTAssertEqual(avcc.count, nals.reduce(0) { $0 + $1.count + 4 })
        // 首个长度前缀 = 2（大端）
        XCTAssertEqual(avcc[avcc.startIndex], 0)
        XCTAssertEqual(avcc[avcc.startIndex + 3], 2)
    }

    func testIPv4ValidationMirrorsAndroidM1Gate() {
        XCTAssertEqual(HostSession.parseIPv4("192.168.1.23"), "192.168.1.23")
        XCTAssertNil(HostSession.parseIPv4("hyperdisplay.local"))
        XCTAssertNil(HostSession.parseIPv4("300.1.1.1"))
        XCTAssertNil(HostSession.parseIPv4("1.2.3"))
    }
}
