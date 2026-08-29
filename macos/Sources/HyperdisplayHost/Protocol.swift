import Foundation

// UDP 线协议 v3（little-endian）。v3 起媒体/输入/重传报文全部携带 displayId，
// 支持一个客户端同时订阅多块虚拟屏（平板分屏）。
//
// 公共头：[type u8][seq u32]
// host→client：
//   WELCOME       seq=0        [displayId u16][proto u8][codec u8][width u16][height u16][fps u8][controlEnabled u8]
//   VIDEO_FRAG    seq=frameId  [displayId u16][fragIdx u16][fragCount u16][flags u8(bit0=keyframe)][payload ≤1100B]
//   CONFIG        seq=frameId  [displayId u16][codec u8][len u16][Annex-B 参数集]
//   DISPLAYS      seq=0        [count u8] × { [id u32][w u16][h u16][nameLen u8][name] }
//   INPUT_ACK     seq=被确认的输入 seq
//   PONG          seq=回显 ping 的 seq
//   CURSOR_IMAGE  seq=imageId [fragIdx u16][fragCount u16][w u16][h u16][hotX i16][hotY i16][BGRA payload]
// client→host：
//   HELLO         seq=0        [proto u8][clientW u16][clientH u16][code u32][deviceId u32]
//                                  [screenCount u8][w,h]×n[fingerprint u64][layout 15B]
//                                  [deviceNameLen u8][UTF-8 deviceName optional]
//   KEYFRAME_REQ               [displayId u16]（0xFFFF = 全部）
//   NACK          seq=0        [displayId u16][frameId u32][count u16][fragIdx u16 × count]
//   SELECT_DISPLAY id u32       —— 订阅集 = {id}（单屏模式）
//   SUBSCRIBE_DISPLAYS         [count u8][id u32 × count] —— 订阅集 = 列表（分屏模式）
//   CREATE_DISPLAY w u16 h u16 nameLen u8 name
//   DESTROY_DISPLAY id u32
//   INPUT         seq          [displayId u16][subtype u8][body]
//     move   x f32 y f32
//     button button u8 (0=left 1=right) down u8 x f32 y f32
//     wheel  dx f32 dy f32 x f32 y f32
//   PING
//   CURSOR_IMAGE_ACK seq=imageId —— 光标图像分片已完整收到
//   DISPLAY_MODE_STATUS 可靠状态（Host→client，client 以 DISPLAY_MODE_STATUS_ACK 确认）
//   LAYOUT_RESTORE_ACK —— 客户端已应用 Host 回传的重装恢复布局

enum PacketType: UInt8 {
    case welcome = 0x01, videoFrag = 0x02, config = 0x03, inputAck = 0x05, pong = 0x06, displays = 0x07, cursor = 0x08, cursorImage = 0x09, savedLayout = 0x0A, displayModeStatus = 0x0B
    /// 会话期无线保活空包：客户端 parse default 返回 nil 直接丢弃，无状态副作用
    case linkKeepalive = 0x0C
    case hello = 0x10, keyframeReq = 0x11, input = 0x12, ping = 0x13
    case selectDisplay = 0x14, createDisplay = 0x15, destroyDisplay = 0x16, nack = 0x17, subscribeDisplays = 0x18
    case cursorImageAck = 0x19, bye = 0x1A, encoderReset = 0x1B, setTier = 0x1C, layoutRestoreAck = 0x1D, displayModeStatusAck = 0x1E
}

/// 0xFFFF 表示「全部显示屏」（KEYFRAME_REQ 专用）
let displayIdBroadcast: UInt16 = 0xFFFF

enum InputSubtype: UInt8 { case move = 0, button = 1, wheel = 2 }

struct DisplayListEntry {
    var id: UInt32
    var width: UInt16
    var height: UInt16
    var name: String
}

/// HELLO 追加字段中的目标屏规格。旧客户端不带该字段时，Host 仍以 clientWidth/clientHeight
/// 创建一块默认副屏；新客户端以此恢复一台平板上次使用的单屏或分屏布局。
struct RequestedDisplaySpec {
    let width: UInt16
    let height: UInt16
}

/// 平板布局的固定 15-byte 快照。它只在该平板卸载重装且 Host 指纹命中时回传，
/// 让 Android 的分屏/画中画视图与已复用的 macOS 屏幕组同步恢复。
struct DeviceLayoutState: Codable, Equatable {
    let kind: UInt8
    let fractionPermille: UInt16
    let sideLeft: Bool
    let pipRatio: UInt8
    let pipCustomW: UInt16
    let pipCustomH: UInt16
    let displayLongEdge: UInt16
    let pipLeft: Int16
    let pipTop: Int16
    /// 可选扩展：固定 15-byte 基础布局保持不变，旧安装/旧 Host 可以忽略尾部。
    let displaySizePreset: UInt8?
    /// 0=明确标准 1x，1=严格请求 Retina 2x；nil=旧客户端，保留历史默认行为。
    let clarity: UInt8?
    /// 一次用户发起的显示模式变更标识，用于让迟到 UDP 状态不能覆盖新意图。
    let transaction: UInt32?

    init(kind: UInt8, fractionPermille: UInt16, sideLeft: Bool, pipRatio: UInt8,
         pipCustomW: UInt16, pipCustomH: UInt16, displayLongEdge: UInt16,
         pipLeft: Int16, pipTop: Int16, displaySizePreset: UInt8? = nil,
         clarity: UInt8? = nil, transaction: UInt32? = nil) {
        self.kind = kind
        self.fractionPermille = fractionPermille
        self.sideLeft = sideLeft
        self.pipRatio = pipRatio
        self.pipCustomW = pipCustomW
        self.pipCustomH = pipCustomH
        self.displayLongEdge = displayLongEdge
        self.pipLeft = pipLeft
        self.pipTop = pipTop
        self.displaySizePreset = displaySizePreset
        self.clarity = clarity
        self.transaction = transaction
    }

    var requestsStrictRetina: Bool { clarity == 1 }
}

enum DisplayModeStatus: UInt8 {
    case validating = 0, ready = 1, unsupported = 2, failed = 3
}

enum Packet {
    case hello(proto: UInt8, clientWidth: UInt16, clientHeight: UInt16, code: UInt32, deviceId: UInt32,
               requestedDisplays: [RequestedDisplaySpec], deviceFingerprint: UInt64, layout: DeviceLayoutState?,
               deviceName: String)
    case keyframeReq(displayId: UInt16)
    case nack(displayId: UInt16, frameId: UInt32, indices: [UInt16])
    case inputMove(displayId: UInt16, seq: UInt32, x: Float32, y: Float32)
    case inputButton(displayId: UInt16, seq: UInt32, button: UInt8, down: UInt8, x: Float32, y: Float32)
    case inputWheel(displayId: UInt16, seq: UInt32, dx: Float32, dy: Float32, x: Float32, y: Float32)
    case ping(seq: UInt32)
    case selectDisplay(id: UInt32)
    case subscribeDisplays(ids: [UInt32])
    case createDisplay(width: UInt16, height: UInt16, name: String)
    case destroyDisplay(id: UInt32)
    case encoderReset(displayId: UInt16)
    case setTier(displayId: UInt16, width: UInt16, height: UInt16)
    case cursorImageAck(imageId: UInt32)
    case layoutRestoreAck
    case displayModeStatusAck(transaction: UInt32)
    case bye
}

enum Wire {
    static let fragPayloadSize = 1100
    /// 图像样式不是视频：它需要可靠到达，但绝不能交给 IP 层做大包分片。
    /// 固定头 17B 后保守留在约 1KB，避免 Wi-Fi/USB MTU 边缘丢整个光标样式。
    static let cursorImageFragPayloadSize = 1000
    static let protoVersion: UInt8 = 1
    static let headerSize = 5

    static func header(_ type: PacketType, seq: UInt32) -> [UInt8] {
        var out = [type.rawValue]
        withUnsafeBytes(of: seq.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // MARK: host→client

    /// 预留字段，纯显示产品始终为 false；保留以兼容旧客户端协议。
    static func linkKeepalive() -> Data { Data(header(.linkKeepalive, seq: 0)) }

    static func welcome(codec: UInt8, displayId: UInt16, width: Int, height: Int, fps: Int, controlEnabled: Bool = true) -> Data {
        var d = Data(header(.welcome, seq: 0))
        d.appendLE(displayId)
        d.appendLE(Wire.protoVersion)
        d.appendLE(codec)
        d.appendLE(UInt16(width))
        d.appendLE(UInt16(height))
        d.appendLE(UInt8(fps))
        d.append(controlEnabled ? 1 : 0)
        return d
    }

    static func config(codec: UInt8, displayId: UInt16, frameId: UInt32, paramSets: Data) -> Data {
        var d = Data(header(.config, seq: frameId))
        d.appendLE(displayId)
        d.appendLE(codec)
        d.appendLE(UInt16(paramSets.count))
        d.append(paramSets)
        return d
    }

    /// 一帧 Annex-B 载荷切成 VIDEO_FRAG 报文序列
    static func videoFrags(displayId: UInt16, frameId: UInt32, keyframe: Bool, payload: Data) -> [Data] {
        let fragCount = UInt16(ceil(Double(payload.count) / Double(fragPayloadSize)))
        var out = [Data]()
        out.reserveCapacity(Int(fragCount))
        var offset = 0
        while offset < payload.count {
            let end = min(offset + fragPayloadSize, payload.count)
            var d = Data(header(.videoFrag, seq: frameId))
            d.appendLE(displayId)
            d.appendLE(UInt16(out.count))
            d.appendLE(fragCount)
            d.appendLE(UInt8(keyframe ? 1 : 0))
            d.append(payload.subdata(in: offset..<end))
            out.append(d)
            offset = end
        }
        return out
    }

    static func displaysList(_ entries: [DisplayListEntry]) -> Data {
        var d = Data(header(.displays, seq: 0))
        d.appendLE(UInt8(min(entries.count, 255)))
        for e in entries {
            let name = Data(e.name.utf8.prefix(60))
            d.appendLE(e.id)
            d.appendLE(e.width)
            d.appendLE(e.height)
            d.appendLE(UInt8(name.count))
            d.append(name)
        }
        return d
    }

    static func savedLayout(_ layout: DeviceLayoutState) -> Data {
        var d = Data(header(.savedLayout, seq: 0))
        d.appendLE(layout.kind)
        d.appendLE(layout.fractionPermille)
        d.appendLE(UInt8(layout.sideLeft ? 1 : 0))
        d.appendLE(layout.pipRatio)
        d.appendLE(layout.pipCustomW)
        d.appendLE(layout.pipCustomH)
        d.appendLE(layout.displayLongEdge)
        d.appendLE(UInt16(bitPattern: layout.pipLeft))
        d.appendLE(UInt16(bitPattern: layout.pipTop))
        // Host→client 的 saved-layout 没有设备名称，扩展紧跟固定基础布局。
        if let size = layout.displaySizePreset, let clarity = layout.clarity {
            d.appendLE(UInt8(0xD2))
            d.appendLE(UInt8(1))
            d.appendLE(size)
            d.appendLE(clarity)
        }
        return d
    }

    /// 可靠的小控制状态：Android 收到后必须回 ACK(transaction)。slot=255 表示整组完成。
    static func displayModeStatus(transaction: UInt32, status: DisplayModeStatus, slot: UInt8,
                                  requestedScale: UInt8, effectiveScale: UInt8) -> Data {
        var d = Data(header(.displayModeStatus, seq: transaction))
        d.appendLE(status.rawValue)
        d.appendLE(slot)
        d.appendLE(requestedScale)
        d.appendLE(effectiveScale)
        return d
    }

    /// 光标位置（常驻本地光标用）。did=0 表示光标已离开虚拟屏（客户端隐藏）。
    static func cursor(displayId: UInt16, x: Float, y: Float) -> Data {
        var d = Data(header(.cursor, seq: 0))
        d.appendLE(displayId)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    /// 系统真实光标的 BGRA 像素。位置仍由 cursor 包以 60Hz 推送；该图像仅在
    /// 哈希变化时出现，客户端完整组装后回 ACK，故不和视频 latest-frame 混用。
    static func cursorImage(imageId: UInt32, width: UInt16, height: UInt16,
                            hotX: Int16, hotY: Int16, pixels: Data) -> [Data] {
        guard !pixels.isEmpty else { return [] }
        let count = UInt16(ceil(Double(pixels.count) / Double(cursorImageFragPayloadSize)))
        guard count > 0 else { return [] }
        var packets: [Data] = []
        packets.reserveCapacity(Int(count))
        var offset = 0
        while offset < pixels.count {
            let end = min(offset + cursorImageFragPayloadSize, pixels.count)
            var d = Data(header(.cursorImage, seq: imageId))
            d.appendLE(UInt16(packets.count))
            d.appendLE(count)
            d.appendLE(width)
            d.appendLE(height)
            d.appendLE(hotX)
            d.appendLE(hotY)
            d.append(pixels.subdata(in: offset..<end))
            packets.append(d)
            offset = end
        }
        return packets
    }

    static func inputAck(seq: UInt32) -> Data {
        Data(header(.inputAck, seq: seq))
    }

    static func pong(seq: UInt32, known: Bool) -> Data {
        // 尾字节 known 标志：host 是否仍认得这个来源（有活跃订阅）。客户端见
        // unknown 即重发 HELLO 重新入会，避免来源端口变化后继续等待旧会话。
        var d = Data(header(.pong, seq: seq))
        d.append(known ? 1 : 0)
        return d
    }

    // MARK: client→host

    static func keyframeReq(seq: UInt32, displayId: UInt16) -> Data {
        var d = Data(header(.keyframeReq, seq: seq))
        d.appendLE(displayId)
        return d
    }

    static func ping(seq: UInt32) -> Data {
        Data(header(.ping, seq: seq))
    }

    static func selectDisplay(id: UInt32) -> Data {
        var d = Data(header(.selectDisplay, seq: 0))
        d.appendLE(id)
        return d
    }

    static func subscribeDisplays(ids: [UInt32]) -> Data {
        var d = Data(header(.subscribeDisplays, seq: 0))
        d.appendLE(UInt8(min(ids.count, 255)))
        for id in ids.prefix(255) {
            d.appendLE(id)
        }
        return d
    }

    static func createDisplay(width: UInt16, height: UInt16, name: String) -> Data {
        var d = Data(header(.createDisplay, seq: 0))
        d.appendLE(width)
        d.appendLE(height)
        let n = Data(name.utf8.prefix(60))
        d.appendLE(UInt8(n.count))
        d.append(n)
        return d
    }

    static func destroyDisplay(id: UInt32) -> Data {
        var d = Data(header(.destroyDisplay, seq: 0))
        d.appendLE(id)
        return d
    }

    static func inputMove(displayId: UInt16, seq: UInt32, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(displayId)
        d.appendLE(InputSubtype.move.rawValue)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func inputButton(displayId: UInt16, seq: UInt32, button: UInt8, down: Bool, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(displayId)
        d.appendLE(InputSubtype.button.rawValue)
        d.appendLE(button)
        d.appendLE(UInt8(down ? 1 : 0))
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func inputWheel(displayId: UInt16, seq: UInt32, dx: Float32, dy: Float32, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(displayId)
        d.appendLE(InputSubtype.wheel.rawValue)
        d.appendLE(dx)
        d.appendLE(dy)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func nack(displayId: UInt16, frameId: UInt32, indices: [UInt16]) -> Data {
        var d = Data(header(.nack, seq: 0))
        d.appendLE(displayId)
        d.appendLE(frameId)
        d.appendLE(UInt16(min(indices.count, 255)))
        for i in indices.prefix(255) {
            d.appendLE(i)
        }
        return d
    }

    // MARK: 解析（client→host 报文）

    static func parse(_ data: Data) -> Packet? {
        guard data.count >= headerSize else { return nil }
        let type = data[data.startIndex]
        let seq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian }
        let body = data.count - headerSize

        func u8(_ off: Int) -> UInt8 { data[data.startIndex + Wire.headerSize + off] }
        func u16(_ off: Int) -> UInt16 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt16.self).littleEndian }
        }
        func u32(_ off: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt32.self).littleEndian }
        }
        func u64(_ off: Int) -> UInt64 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt64.self).littleEndian }
        }
        func f32(_ off: Int) -> Float32 {
            Float32(bitPattern: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt32.self).littleEndian
            })
        }

        switch type {
        case PacketType.hello.rawValue:
            guard body >= 5 else { return nil }
            // [proto][w][h][code u32][deviceId u32]——code 配对码，deviceId 是旧版
            // 安装内标识。可选尾部 fingerprint 是匿名且跨卸载稳定的设备归并键。
            let code: UInt32 = body >= 9 ? u32(5) : 0
            let deviceId: UInt32 = body >= 13 ? u32(9) : 0
            var requested: [RequestedDisplaySpec] = []
            // 可选尾部：[count u8][width u16][height u16]×count。最多四块，避免异常包
            // 触发批量建屏；旧 HELLO 只有 13-byte body，继续兼容。
            if body >= 14 {
                let count = Int(u8(13))
                guard count <= 4 else { return nil }
                guard body >= 14 + count * 4 else { return nil }
                requested.reserveCapacity(count)
                for i in 0..<count {
                    requested.append(RequestedDisplaySpec(width: u16(14 + i * 4), height: u16(16 + i * 4)))
                }
            }
            let fingerprintOffset = 14 + requested.count * 4
            let deviceFingerprint: UInt64 = body >= fingerprintOffset + 8 ? u64(fingerprintOffset) : 0
            let layoutOffset = fingerprintOffset + 8
            let baseLayout: DeviceLayoutState?
            if body >= layoutOffset + 15 {
                baseLayout = DeviceLayoutState(
                    kind: u8(layoutOffset), fractionPermille: u16(layoutOffset + 1),
                    sideLeft: (u8(layoutOffset + 3) & 1) != 0, pipRatio: u8(layoutOffset + 4),
                    pipCustomW: u16(layoutOffset + 5), pipCustomH: u16(layoutOffset + 7),
                    displayLongEdge: u16(layoutOffset + 9),
                    pipLeft: Int16(bitPattern: u16(layoutOffset + 11)),
                    pipTop: Int16(bitPattern: u16(layoutOffset + 13)))
            } else {
                baseLayout = nil
            }
            let nameOffset = layoutOffset + (baseLayout == nil ? 0 : 15)
            var deviceName = ""
            var extensionOffset = nameOffset
            if body > nameOffset {
                let nameLength = Int(u8(nameOffset))
                guard nameLength <= 64, body >= nameOffset + 1 + nameLength else { return nil }
                deviceName = String(data: data.subdata(in: (Wire.headerSize + nameOffset + 1)..<(Wire.headerSize + nameOffset + 1 + nameLength)),
                                    encoding: .utf8) ?? ""
                extensionOffset = nameOffset + 1 + nameLength
            }
            var layout = baseLayout
            // HELLO 扩展放在名称之后，因此旧 Host 会完整读到名称并安全忽略尾部。
            // [marker D2][version 1][size preset][clarity][transaction u32]
            if let base = baseLayout, body >= extensionOffset + 8,
               u8(extensionOffset) == 0xD2, u8(extensionOffset + 1) == 1 {
                layout = DeviceLayoutState(
                    kind: base.kind, fractionPermille: base.fractionPermille, sideLeft: base.sideLeft,
                    pipRatio: base.pipRatio, pipCustomW: base.pipCustomW, pipCustomH: base.pipCustomH,
                    displayLongEdge: base.displayLongEdge, pipLeft: base.pipLeft, pipTop: base.pipTop,
                    displaySizePreset: u8(extensionOffset + 2), clarity: u8(extensionOffset + 3),
                    transaction: u32(extensionOffset + 4))
            }
            return .hello(proto: u8(0), clientWidth: u16(1), clientHeight: u16(3), code: code, deviceId: deviceId,
                          requestedDisplays: requested, deviceFingerprint: deviceFingerprint, layout: layout,
                          deviceName: deviceName)
        case PacketType.keyframeReq.rawValue:
            guard body >= 2 else { return nil }
            return .keyframeReq(displayId: u16(0))
        case PacketType.nack.rawValue:
            guard body >= 8 else { return nil }
            let count = Int(u16(6))
            guard body >= 8 + count * 2 else { return nil }
            var indices = [UInt16]()
            indices.reserveCapacity(count)
            for i in 0..<count {
                indices.append(u16(8 + i * 2))
            }
            return .nack(displayId: u16(0), frameId: u32(2), indices: indices)
        case PacketType.ping.rawValue:
            return .ping(seq: seq)
        case PacketType.selectDisplay.rawValue:
            guard body >= 4 else { return nil }
            return .selectDisplay(id: u32(0))
        case PacketType.subscribeDisplays.rawValue:
            guard body >= 1 else { return nil }
            let count = Int(u8(0))
            guard body >= 1 + count * 4 else { return nil }
            var ids = [UInt32]()
            ids.reserveCapacity(count)
            for i in 0..<count {
                ids.append(u32(1 + i * 4))
            }
            return .subscribeDisplays(ids: ids)
        case PacketType.createDisplay.rawValue:
            guard body >= 5 else { return nil }
            let w = u16(0), h = u16(2), nameLen = Int(u8(4))
            guard body >= 5 + nameLen else { return nil }
            let name = String(data: data.subdata(in: Wire.headerSize + 5..<Wire.headerSize + 5 + nameLen), encoding: .utf8) ?? ""
            return .createDisplay(width: w, height: h, name: name)
        case PacketType.destroyDisplay.rawValue:
            guard body >= 4 else { return nil }
            return .destroyDisplay(id: u32(0))
        case PacketType.encoderReset.rawValue:
            guard body >= 2 else { return nil }
            return .encoderReset(displayId: u16(0))
        case PacketType.setTier.rawValue:
            guard body >= 6 else { return nil }
            return .setTier(displayId: u16(0), width: u16(2), height: u16(4))
        case PacketType.cursorImageAck.rawValue:
            return .cursorImageAck(imageId: seq)
        case PacketType.layoutRestoreAck.rawValue:
            return .layoutRestoreAck
        case PacketType.displayModeStatusAck.rawValue:
            return .displayModeStatusAck(transaction: seq)
        case PacketType.bye.rawValue:
            return .bye
        case PacketType.input.rawValue:
            guard body >= 3 else { return nil }
            let displayId = u16(0)
            switch InputSubtype(rawValue: u8(2)) {
            case .move:
                guard body >= 11 else { return nil }
                return .inputMove(displayId: displayId, seq: seq, x: f32(3), y: f32(7))
            case .button:
                guard body >= 13 else { return nil }
                return .inputButton(displayId: displayId, seq: seq, button: u8(3), down: u8(4), x: f32(5), y: f32(9))
            case .wheel:
                guard body >= 19 else { return nil }
                return .inputWheel(displayId: displayId, seq: seq, dx: f32(3), dy: f32(7), x: f32(11), y: f32(15))
            case nil:
                return nil
            }
        default:
            return nil
        }
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt64) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt8) {
        append(v)
    }
    mutating func appendLE(_ v: Int16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: Float32) {
        Swift.withUnsafeBytes(of: v.bitPattern.littleEndian) { append(contentsOf: $0) }
    }
}
