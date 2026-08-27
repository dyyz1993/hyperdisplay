import Foundation

private func helloPacket(screenCount: UInt8, includeLayout: Bool, deviceName: String? = nil,
                         retinaExtension: Bool = false) -> Data {
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
    if let deviceName {
        let bytes = Array(deviceName.utf8.prefix(64))
        data.appendLE(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    if retinaExtension {
        data.appendLE(UInt8(0xD2))
        data.appendLE(UInt8(1))
        data.appendLE(UInt8(3)) // 标准尺寸档
        data.appendLE(UInt8(1)) // strict Retina
        data.appendLE(UInt32(42))
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
        guard case let .hello(proto, width, height, code, deviceId, screens, fingerprint, layout, deviceName)? =
                Wire.parse(helloPacket(screenCount: 2, includeLayout: true, deviceName: "DBY2-W00", retinaExtension: true)) else {
            fputs("FAIL: full HELLO did not parse\n", stderr)
            exit(1)
        }
        check(proto == 1 && width == 2800 && height == 1840, "HELLO display dimensions")
        check(code == 123_456 && deviceId == 998_877, "HELLO pairing and installation IDs")
        check(screens.count == 2 && screens.allSatisfy { $0.width == 1400 && $0.height == 1840 },
              "two-screen request must survive parsing")
        check(fingerprint == 0x1122_3344_5566_7788, "stable fingerprint")
        check(layout?.kind == 1 && layout?.displayLongEdge == 2_240, "saved layout fields")
        check(layout?.displaySizePreset == 3 && layout?.clarity == 1 && layout?.transaction == 42,
              "optional strict Retina extension survives HELLO parsing")
        check(deviceName == "DBY2-W00", "optional device name")

        // 布局是身份边界：不同布局必须有独立 EDID；同一布局内无论尺寸档位或比例
        // 怎么变，身份都不能变化，macOS 才能恢复它自己的编排和窗口归属。
        let topologyDeviceId: UInt32 = 998_877
        let single = DeviceTopologyIdentity.edid(deviceId: topologyDeviceId, topology: .single, slot: 0)
        let leftRight0 = DeviceTopologyIdentity.edid(deviceId: topologyDeviceId, topology: .splitLeftRight, slot: 0)
        let leftRight1 = DeviceTopologyIdentity.edid(deviceId: topologyDeviceId, topology: .splitLeftRight, slot: 1)
        let topBottom0 = DeviceTopologyIdentity.edid(deviceId: topologyDeviceId, topology: .splitTopBottom, slot: 0)
        check(single.productID == 0x0001 && single.serial == 1000 + (topologyDeviceId & 0xFFFF),
              "single display keeps the pre-v2 identity")
        check(leftRight0 != single && leftRight0 != topBottom0,
              "different layout profiles must never share slot-zero identity")
        check(leftRight0 != leftRight1,
              "screens inside a split layout need distinct identities")
        check(DeviceTopologyIdentity.edid(deviceId: topologyDeviceId, topology: .splitLeftRight, slot: 0) == leftRight0,
              "resolution tiers and divider fractions must not change an existing layout identity")
        check(DeviceTopology(layoutKind: nil, requestedScreenCount: 1) == .single &&
              DeviceTopology(layoutKind: nil, requestedScreenCount: 2) == .splitLeftRight,
              "legacy clients receive non-colliding fallback topologies")
        check(DeviceTopology.single.virtualDisplayName(deviceName: "DBY2-W00", slot: 0, screenCount: 1) == "DBY2-W00",
              "single display should use the device name directly")
        check(DeviceTopology.splitLeftRight.virtualDisplayName(deviceName: "DBY2-W00", slot: 1, screenCount: 2) ==
              "DBY2-W00 · 左右分屏 2", "split display must have a fixed, numbered label")
        check(DeviceTopology.pictureInPicture.virtualDisplayName(deviceName: "Redmi Note 7", slot: 1, screenCount: 2) ==
              "Redmi Note 7 · 画中画", "picture-in-picture labels should identify the role")

        var ack = Data(Wire.header(.layoutRestoreAck, seq: 0))
        check({ if case .layoutRestoreAck? = Wire.parse(ack) { return true }; return false }(),
              "layout restore acknowledgement")
        ack.append(0) // packet remains valid with harmless forward-compatible tail data.
        check({ if case .layoutRestoreAck? = Wire.parse(ack) { return true }; return false }(),
              "layout acknowledgement tail compatibility")

        var statusAck = Data(Wire.header(.displayModeStatusAck, seq: 42))
        check({ if case let .displayModeStatusAck(transaction)? = Wire.parse(statusAck) { return transaction == 42 }; return false }(),
              "Retina mode status acknowledgement")
        statusAck.append(0)
        check({ if case let .displayModeStatusAck(transaction)? = Wire.parse(statusAck) { return transaction == 42 }; return false }(),
              "status acknowledgement accepts harmless tail data")

        check(Wire.parse(helloPacket(screenCount: 5, includeLayout: false)) == nil,
              "oversized screen group must be rejected before any display work")
        print("Protocol contract tests passed")
    }
}
