import Foundation

// UDP 线协议 v3（little-endian）。v3 起媒体/输入/重传报文全部携带 displayId，
// 支持一个客户端同时订阅多块虚拟屏（平板分屏）。
//
// 公共头：[type u8][seq u32]
// host→client：
//   WELCOME       seq=0        [displayId u16][proto u8][codec u8][width u16][height u16][fps u8]
//   VIDEO_FRAG    seq=frameId  [displayId u16][fragIdx u16][fragCount u16][flags u8(bit0=keyframe)][payload ≤1100B]
//   CONFIG        seq=frameId  [displayId u16][codec u8][len u16][Annex-B 参数集]
//   DISPLAYS      seq=0        [count u8] × { [id u32][w u16][h u16][nameLen u8][name] }
//   INPUT_ACK     seq=被确认的输入 seq
//   PONG          seq=回显 ping 的 seq
// client→host：
//   HELLO         seq=0        [proto u8][clientW u16][clientH u16]
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

enum PacketType: UInt8 {
    case welcome = 0x01, videoFrag = 0x02, config = 0x03, inputAck = 0x05, pong = 0x06, displays = 0x07, cursor = 0x08
    case hello = 0x10, keyframeReq = 0x11, input = 0x12, ping = 0x13
    case selectDisplay = 0x14, createDisplay = 0x15, destroyDisplay = 0x16, nack = 0x17, subscribeDisplays = 0x18, recycle = 0x19
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

enum Packet {
    case hello(proto: UInt8, clientWidth: UInt16, clientHeight: UInt16, code: UInt32)
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
    case recycle
}

enum Wire {
    static let fragPayloadSize = 1100
    static let protoVersion: UInt8 = 1
    static let headerSize = 5

    static func header(_ type: PacketType, seq: UInt32) -> [UInt8] {
        var out = [type.rawValue]
        withUnsafeBytes(of: seq.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // MARK: host→client

    static func welcome(codec: UInt8, displayId: UInt16, width: Int, height: Int, fps: Int) -> Data {
        var d = Data(header(.welcome, seq: 0))
        d.appendLE(displayId)
        d.appendLE(Wire.protoVersion)
        d.appendLE(codec)
        d.appendLE(UInt16(width))
        d.appendLE(UInt16(height))
        d.appendLE(UInt8(fps))
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

    /// 光标位置（常驻本地光标用）。did=0 表示光标已离开虚拟屏（客户端隐藏）。
    static func cursor(displayId: UInt16, x: Float, y: Float) -> Data {
        var d = Data(header(.cursor, seq: 0))
        d.appendLE(displayId)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func inputAck(seq: UInt32) -> Data {
        Data(header(.inputAck, seq: seq))
    }

    static func pong(seq: UInt32) -> Data {
        Data(header(.pong, seq: seq))
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
        func f32(_ off: Int) -> Float32 {
            Float32(bitPattern: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt32.self).littleEndian
            })
        }

        switch type {
        case PacketType.hello.rawValue:
            guard body >= 5 else { return nil }
            // code 为配对码（旧客户端不带 → 0 → 拒绝）；body>=9 才有
            let code: UInt32 = body >= 9 ? u32(5) : 0
            return .hello(proto: u8(0), clientWidth: u16(1), clientHeight: u16(3), code: code)
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
        case PacketType.recycle.rawValue:
            return .recycle
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
    mutating func appendLE(_ v: UInt8) {
        append(v)
    }
    mutating func appendLE(_ v: Float32) {
        Swift.withUnsafeBytes(of: v.bitPattern.littleEndian) { append(contentsOf: $0) }
    }
}
