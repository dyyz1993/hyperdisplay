import Foundation

// UDP 线协议 v2（little-endian）。
// 公共头：[type u8][seq u32]
// 视频（host→client，不可靠）：
//   VIDEO_FRAG  seq=frameId  [fragIdx u16][fragCount u16][flags u8 (bit0=keyframe)][payload ≤1100B]
//   CONFIG      seq=frameId  [codec u8][len u16][Annex-B 参数集]
//   WELCOME     seq=0        [proto u8][codec u8][width u16][height u16][fps u8]
//   DISPLAYS    seq=0        [count u8] × { [id u32][w u16][h u16][nameLen u8][name] }
//   INPUT_ACK   seq=被确认的输入 seq
//   PONG        seq=回显 ping 的 seq
// 控制/输入（client→host，按键/滚轮走 seq+ack 重传）：
//   HELLO       seq=0        [proto u8][clientW u16][clientH u16]
//   KEYFRAME_REQ
//   SELECT_DISPLAY id u32            —— 切换到指定虚拟屏
//   CREATE_DISPLAY w u16 h u16 nameLen u8 name —— 新建并切换
//   DESTROY_DISPLAY id u32           —— 删除（最后一块会拒绝）
//   INPUT       seq          [subtype u8][body]
//     move   x f32 y f32
//     button button u8 (0=left 1=right) down u8 x f32 y f32
//     wheel  dx f32 dy f32 x f32 y f32
//   PING

enum PacketType: UInt8 {
    case welcome = 0x01, videoFrag = 0x02, config = 0x03, displays = 0x07, inputAck = 0x05, pong = 0x06
    case hello = 0x10, keyframeReq = 0x11, input = 0x12, ping = 0x13
    case selectDisplay = 0x14, createDisplay = 0x15, destroyDisplay = 0x16
    case nack = 0x17
}

enum InputSubtype: UInt8 { case move = 0, button = 1, wheel = 2 }

struct DisplayListEntry {
    var id: UInt32
    var width: UInt16
    var height: UInt16
    var name: String
}

enum Packet {
    case hello(proto: UInt8, clientWidth: UInt16, clientHeight: UInt16)
    case keyframeReq
    case inputMove(seq: UInt32, x: Float32, y: Float32)
    case inputButton(seq: UInt32, button: UInt8, down: UInt8, x: Float32, y: Float32)
    case inputWheel(seq: UInt32, dx: Float32, dy: Float32, x: Float32, y: Float32)
    case ping(seq: UInt32)
    case selectDisplay(id: UInt32)
    case createDisplay(width: UInt16, height: UInt16, name: String)
    case destroyDisplay(id: UInt32)
    case nack(frameId: UInt32, indices: [UInt16])
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

    static func welcome(codec: UInt8, width: Int, height: Int, fps: Int) -> Data {
        var d = Data(header(.welcome, seq: 0))
        d.appendLE(Wire.protoVersion)
        d.appendLE(codec)
        d.appendLE(UInt16(width))
        d.appendLE(UInt16(height))
        d.appendLE(UInt8(fps))
        return d
    }

    static func config(codec: UInt8, frameId: UInt32, paramSets: Data) -> Data {
        var d = Data(header(.config, seq: frameId))
        d.appendLE(codec)
        d.appendLE(UInt16(paramSets.count))
        d.append(paramSets)
        return d
    }

    static func inputAck(seq: UInt32) -> Data {
        Data(header(.inputAck, seq: seq))
    }

    static func pong(seq: UInt32) -> Data {
        Data(header(.pong, seq: seq))
    }

    static func keyframeReq(seq: UInt32) -> Data {
        Data(header(.keyframeReq, seq: seq))
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

    static func selectDisplay(id: UInt32) -> Data {
        var d = Data(header(.selectDisplay, seq: 0))
        d.appendLE(id)
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

    /// NACK：请求重传指定关键帧的缺失分片（仅关键帧需要完整，增量帧可丢）
    static func nack(frameId: UInt32, indices: [UInt16]) -> Data {
        var d = Data(header(.nack, seq: 0))
        d.appendLE(frameId)
        d.appendLE(UInt16(min(indices.count, 255)))
        for i in indices.prefix(255) {
            d.appendLE(i)
        }
        return d
    }

    static func ping(seq: UInt32) -> Data {
        Data(header(.ping, seq: seq))
    }

    static func inputMove(seq: UInt32, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(InputSubtype.move.rawValue)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func inputButton(seq: UInt32, button: UInt8, down: Bool, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(InputSubtype.button.rawValue)
        d.appendLE(button)
        d.appendLE(UInt8(down ? 1 : 0))
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    static func inputWheel(seq: UInt32, dx: Float32, dy: Float32, x: Float32, y: Float32) -> Data {
        var d = Data(header(.input, seq: seq))
        d.appendLE(InputSubtype.wheel.rawValue)
        d.appendLE(dx)
        d.appendLE(dy)
        d.appendLE(x)
        d.appendLE(y)
        return d
    }

    /// 一帧 Annex-B 载荷切成 VIDEO_FRAG 报文序列
    static func videoFrags(frameId: UInt32, keyframe: Bool, payload: Data) -> [Data] {
        let fragCount = UInt16(ceil(Double(payload.count) / Double(fragPayloadSize)))
        var out = [Data]()
        out.reserveCapacity(Int(fragCount))
        var offset = 0
        while offset < payload.count {
            let end = min(offset + fragPayloadSize, payload.count)
            var d = Data(header(.videoFrag, seq: frameId))
            d.appendLE(UInt16(out.count))
            d.appendLE(fragCount)
            d.appendLE(UInt8(keyframe ? 1 : 0))
            d.append(payload.subdata(in: offset..<end))
            out.append(d)
            offset = end
        }
        return out
    }

    static func parse(_ data: Data) -> Packet? {
        guard data.count >= headerSize else { return nil }
        let type = data[data.startIndex]
        let seq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian }
        let body = data.count - headerSize

        func u8(_ off: Int) -> UInt8 { data[data.startIndex + Wire.headerSize + off] }
        func u16(_ off: Int) -> UInt16 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt16.self).littleEndian }
        }
        func f32(_ off: Int) -> Float32 {
            Float32(bitPattern: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize + off, as: UInt32.self).littleEndian
            })
        }

        switch type {
        case PacketType.hello.rawValue:
            guard body >= 5 else { return nil }
            return .hello(proto: u8(0), clientWidth: u16(1), clientHeight: u16(3))
        case PacketType.keyframeReq.rawValue:
            return .keyframeReq
        case PacketType.ping.rawValue:
            return .ping(seq: seq)
        case PacketType.selectDisplay.rawValue:
            guard body >= 4 else { return nil }
            return .selectDisplay(id: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize, as: UInt32.self).littleEndian
            })
        case PacketType.createDisplay.rawValue:
            guard body >= 5 else { return nil }
            let w = u16(0), h = u16(2), nameLen = Int(u8(4))
            guard body >= 5 + nameLen else { return nil }
            let name = String(data: data.subdata(in: Wire.headerSize + 5..<Wire.headerSize + 5 + nameLen), encoding: .utf8) ?? ""
            return .createDisplay(width: w, height: h, name: name)
        case PacketType.destroyDisplay.rawValue:
            guard body >= 4 else { return nil }
            return .destroyDisplay(id: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize, as: UInt32.self).littleEndian
            })
        case PacketType.nack.rawValue:
            guard body >= 6 else { return nil }
            let frameId = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: Wire.headerSize, as: UInt32.self).littleEndian
            }
            let count = Int(u16(4))
            guard body >= 6 + count * 2 else { return nil }
            var indices = [UInt16]()
            indices.reserveCapacity(count)
            for i in 0..<count {
                indices.append(u16(6 + i * 2))
            }
            return .nack(frameId: frameId, indices: indices)
        case PacketType.input.rawValue:
            guard body >= 1 else { return nil }
            switch InputSubtype(rawValue: u8(0)) {
            case .move:
                guard body >= 9 else { return nil }
                return .inputMove(seq: seq, x: f32(1), y: f32(5))
            case .button:
                guard body >= 11 else { return nil }
                return .inputButton(seq: seq, button: u8(1), down: u8(2), x: f32(3), y: f32(7))
            case .wheel:
                guard body >= 17 else { return nil }
                return .inputWheel(seq: seq, dx: f32(1), dy: f32(5), x: f32(9), y: f32(13))
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
