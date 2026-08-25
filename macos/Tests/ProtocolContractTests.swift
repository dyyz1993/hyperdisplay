import Foundation

private func helloPacket(screenCount: UInt8, includeLayout: Bool) -> Data {
    var data = Data(Wire.header(.hello, seq: 0))
    data.appendLE(UInt8(1))
    data.appendLE(UInt16(2800))
    data.appendLE(UInt16(1840))
    data.appendLE(UInt32(123_456))
    data.appendLE(UInt32(998_877))
    data.appendLE(screenCount)
    for _ in 0..<screenCount {
        data.appendLE(UInt16(1400))
        data.appendLE(UInt16(1840))
    }
    data.appendLE(UInt64(0x1122_3344_5566_7788))
    if includeLayout {
        let layout = DeviceLayoutState(kind: 1, fractionPermille: 5_000, sideLeft: false,
                                       pipRatio: 0, pipCustomW: 0, pipCustomH: 0,
                                       displayLongEdge: 2_240, pipLeft: -1, pipTop: -1)
        data.appendLE(layout.kind)
        data.appendLE(layout.fractionPermille)
        data.appendLE(UInt8(layout.sideLeft ? 1 : 0))
        data.appendLE(layout.pipRatio)
        data.appendLE(layout.pipCustomW)
        data.appendLE(layout.pipCustomH)
        data.appendLE(layout.displayLongEdge)
        data.appendLE(UInt16(bitPattern: layout.pipLeft))
        data.appendLE(UInt16(bitPattern: layout.pipTop))
    }
    return data
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ProtocolContractTests {
    static func main() {
        guard case let .hello(proto, width, height, code, deviceId, screens, fingerprint, layout)? =
                Wire.parse(helloPacket(screenCount: 2, includeLayout: true)) else {
            fputs("FAIL: full HELLO did not parse\n", stderr)
            exit(1)
        }
        check(proto == 1 && width == 2800 && height == 1840, "HELLO display dimensions")
        check(code == 123_456 && deviceId == 998_877, "HELLO pairing and installation IDs")
        check(screens.count == 2 && screens.allSatisfy { $0.width == 1400 && $0.height == 1840 },
              "two-screen request must survive parsing")
        check(fingerprint == 0x1122_3344_5566_7788, "stable fingerprint")
        check(layout?.kind == 1 && layout?.displayLongEdge == 2_240, "saved layout fields")

        var ack = Data(Wire.header(.layoutRestoreAck, seq: 0))
        check({ if case .layoutRestoreAck? = Wire.parse(ack) { return true }; return false }(),
              "layout restore acknowledgement")
        ack.append(0) // packet remains valid with harmless forward-compatible tail data.
        check({ if case .layoutRestoreAck? = Wire.parse(ack) { return true }; return false }(),
              "layout acknowledgement tail compatibility")

        check(Wire.parse(helloPacket(screenCount: 5, includeLayout: false)) == nil,
              "oversized screen group must be rejected before any display work")
        print("Protocol contract tests passed")
    }
}
