import Foundation

// UDP 线协议 v1（little-endian）客户端编解码。
// 权威字节级定义见 macos/Sources/HyperdisplayHost/Protocol.swift 与
// android/.../HostSession.kt；本文件只实现 iOS 客户端用到的一半：
// client→host 的构造 + host→client 的解析。产品口径为纯显示（README v0.3.3），
// INPUT/按键/滚轮注入不移植。

enum PacketType: UInt8 {
    case welcome = 0x01, videoFrag = 0x02, config = 0x03, inputAck = 0x05, pong = 0x06
    case displays = 0x07, cursor = 0x08, cursorImage = 0x09, savedLayout = 0x0A
    case displayModeStatus = 0x0B
    case hello = 0x10, keyframeReq = 0x11, ping = 0x13, selectDisplay = 0x14
    case nack = 0x17, subscribeDisplays = 0x18, cursorImageAck = 0x19, bye = 0x1A
    case layoutRestoreAck = 0x1D, displayModeStatusAck = 0x1E
}

enum DisplayModeStatus: UInt8 {
    case validating = 0, ready = 1, unsupported = 2, failed = 3
}

struct DisplayInfo: Equatable {
    let id: UInt32
    let width: UInt16
    let height: UInt16
    let name: String
}

/// HELLO 可选尾部里的目标屏规格。阶段一恒为空列表：host 以 clientWidth/Height 建默认副屏，
/// 与旧客户端单屏路径语义一致。
struct RequestedDisplaySpec: Equatable {
    var width: UInt16
    var height: UInt16
}

/// 15 字节固定布局快照 + 可选 D2 扩展（对照 MainActivity.layoutStateForHost /
/// HostSession.LayoutState.writeTo）。字节序与安卓端逐字段一致。
struct LayoutWire {
    var kind: UInt8 = 0
    var fractionPermille: UInt16 = 5000
    var sideLeft: Bool = false
    var pipRatio: UInt8 = 0
    var pipCustomW: UInt16 = 0
    var pipCustomH: UInt16 = 0
    var displayLongEdge: UInt16 = 0
    var pipLeft: Int16 = -1
    var pipTop: Int16 = -1
    /// D2 扩展：0=原生，1..4 = 1440/1600/1920/2240 档位
    var displaySizePreset: UInt8 = 0
    /// 0=明确标准 1x，1=严格请求实际 Retina 2x
    var clarity: UInt8 = 0
    /// 一次用户发起的显示模式变更标识；迟到的 UDP 状态不得覆盖新意图
    var transaction: UInt32 = 0

    static let byteCount = 15
    static let extensionByteCount = 8

    func encode(into out: inout [UInt8]) {
        out.append(kind.coerceIn(0...4))
        appendLE(&out, fractionPermille.coerceIn(2000...8000))
        out.append(sideLeft ? 1 : 0)
        out.append(pipRatio.coerceIn(0...3))
        appendLE(&out, pipCustomW.coerceIn(0...16_368))
        appendLE(&out, pipCustomH.coerceIn(0...16_368))
        appendLE(&out, displayLongEdge.coerceIn(0...16_368))
        appendLE(&out, pipLeft.coerceIn(-1...16_368))
        appendLE(&out, pipTop.coerceIn(-1...16_368))
    }

    /// HELLO 名称之后的扩展尾部：[D2][version=1][preset][clarity][transaction u32]
    func encodeExtension(into out: inout [UInt8]) {
        out.append(0xD2)
        out.append(1)
        out.append(displaySizePreset.coerceIn(0...4))
        out.append(clarity.coerceIn(0...1))
        appendLE(&out, transaction)
    }

    /// savedLayout（host→client）解析：15B 基础 + 可选 [D2][1][size][clarity]（无 transaction）
    static func decode(base bytes: [UInt8]) -> LayoutWire? {
        guard bytes.count >= byteCount else { return nil }
        var w = LayoutWire()
        w.kind = bytes[0]
        w.fractionPermille = (UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        w.sideLeft = (bytes[3] & 1) != 0
        w.pipRatio = bytes[4]
        w.pipCustomW = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        w.pipCustomH = UInt16(bytes[7]) | (UInt16(bytes[8]) << 8)
        w.displayLongEdge = UInt16(bytes[9]) | (UInt16(bytes[10]) << 8)
        w.pipLeft = Int16(bitPattern: UInt16(bytes[11]) | (UInt16(bytes[12]) << 8))
        w.pipTop = Int16(bitPattern: UInt16(bytes[13]) | (UInt16(bytes[14]) << 8))
        if bytes.count >= byteCount + 4, bytes[byteCount] == 0xD2, bytes[byteCount + 1] == 1 {
            w.displaySizePreset = bytes[byteCount + 2]
            w.clarity = bytes[byteCount + 3]
        }
        return w
    }
}

/// Kotlin coerceIn 的对应物（对照安卓 writeTo 的 clamp 语义）
extension Comparable {
    func coerceIn(_ range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// host→client 报文解析结果
enum HostPacket {
    case welcome(displayId: UInt16, proto: UInt8, codec: UInt8,
                 width: UInt16, height: UInt16, fps: UInt8, controlEnabled: Bool)
    case config(displayId: UInt16, codec: UInt8, paramSets: Data)
    case videoFragment(displayId: UInt16, frameId: UInt32, fragIdx: UInt16, fragCount: UInt16,
                       keyframe: Bool, payload: Data)
    case displays([DisplayInfo])
    /// host 命中设备指纹的卸载重装恢复：完整布局快照（含可选 D2 扩展）
    case savedLayout(LayoutWire)
    case displayModeStatus(transaction: UInt32, status: DisplayModeStatus, slot: UInt8,
                           requestedScale: UInt8, effectiveScale: UInt8)
    /// did=0 表示光标离开虚拟屏（隐藏）
    case cursor(displayId: UInt16, x: Float, y: Float)
    /// 光标 BGRA 位图分片已在会话层组装完整后的产物（client 本地补充语义）
    case cursorBitmap(CursorImage)
    case cursorImage(imageId: UInt32, index: UInt16, count: UInt16,
                     width: UInt16, height: UInt16, hotX: Int16, hotY: Int16, payload: Data)
    case inputAck(seq: UInt32)
    case pong(known: Bool)
}

// MARK: - 字节工具

private func readU8(_ b: [UInt8], _ off: Int) -> UInt8 { b[5 + off] }

private func readU16(_ b: [UInt8], _ off: Int) -> UInt16 {
    UInt16(b[5 + off]) | (UInt16(b[6 + off]) << 8)
}

private func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[5 + off]) | (UInt32(b[6 + off]) << 8) | (UInt32(b[7 + off]) << 16) | (UInt32(b[8 + off]) << 24)
}

private func readU64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in stride(from: 7, through: 0, by: -1) { v = (v << 8) | UInt64(b[5 + off + i]) }
    return v
}

private func readF32(_ b: [UInt8], _ off: Int) -> Float {
    Float(bitPattern: readU32(b, off))
}

func appendLE(_ out: inout [UInt8], _ v: UInt8) { out.append(v) }

func appendLE(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
}

func appendLE(_ out: inout [UInt8], _ v: UInt32) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
}

func appendLE(_ out: inout [UInt8], _ v: UInt64) {
    for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
}

func appendLE(_ out: inout [UInt8], _ v: Int16) { appendLE(&out, UInt16(bitPattern: v)) }

func appendLE(_ out: inout [UInt8], _ v: Float) { appendLE(&out, v.bitPattern) }

/// 组装公共头 [type u8][seq u32 LE] + body
func wirePacket(_ type: PacketType, seq: UInt32 = 0, body: [UInt8] = []) -> Data {
    var out: [UInt8] = []
    out.reserveCapacity(5 + body.count)
    out.append(type.rawValue)
    appendLE(&out, seq)
    out.append(contentsOf: body)
    return Data(out)
}

// MARK: - client→host 构造

enum ClientWire {
    static let protoVersion: UInt8 = 1

    /// HELLO：[proto][w][h][code u32][deviceId u32][count u8][w,h]×n[fingerprint u64]
    ///        [layout 15B][nameLen u8][name][ext D2 01 preset clarity transaction u32]。
    /// 扩展尾在名称之后，旧 Host 读完名称即安全忽略。
    /// layout 为 nil 时省略布局段与 D2 扩展（旧客户端形态）。实测携带 layout 段的
    /// HELLO 会触发当前 host 拓扑的高频推送循环，恢复前默认不发——savedLayout
    /// 恢复与显示模式事务暂不可用（多屏订阅不受影响，specs 照常携带）。
    static func hello(clientWidth: UInt16, clientHeight: UInt16, code: UInt32, deviceId: UInt32,
                      fingerprint: UInt64, deviceName: String,
                      specs: [RequestedDisplaySpec], layout: LayoutWire?) -> Data {
        assert(specs.count <= 4)
        var body: [UInt8] = []
        body.reserveCapacity(14 + specs.count * 4 + 8 + LayoutWire.byteCount
            + 1 + deviceName.utf8.count + LayoutWire.extensionByteCount)
        body.append(protoVersion)
        appendLE(&body, clientWidth)
        appendLE(&body, clientHeight)
        appendLE(&body, code)
        appendLE(&body, deviceId)
        body.append(UInt8(min(specs.count, 4)))
        for s in specs.prefix(4) {
            appendLE(&body, s.width.clamped(to: 640...16_368))
            appendLE(&body, s.height.clamped(to: 480...16_368))
        }
        appendLE(&body, fingerprint)
        if let layout {
            layout.encode(into: &body)
        }
        let nameBytes = Array(deviceName.utf8.prefix(64))
        body.append(UInt8(nameBytes.count))
        body.append(contentsOf: nameBytes)
        layout?.encodeExtension(into: &body)
        return wirePacket(.hello, seq: 0, body: body)
    }

    static func ping(seq: UInt32) -> Data { wirePacket(.ping, seq: seq) }

    /// KEYFRAME_REQ 的公共头 seq 由调用方复用心跳序号（host 不校验该值）
    static func keyframeReq(seq: UInt32, displayId: UInt16) -> Data {
        var body: [UInt8] = []
        appendLE(&body, displayId)
        return wirePacket(.keyframeReq, seq: seq, body: body)
    }

    /// displayId == 0xFFFF 表示全部屏
    static let displayIdBroadcast: UInt16 = 0xFFFF

    static func nack(displayId: UInt16, frameId: UInt32, indices: [UInt16]) -> Data {
        var body: [UInt8] = []
        body.reserveCapacity(8 + min(indices.count, 255) * 2)
        appendLE(&body, displayId)
        appendLE(&body, frameId)
        appendLE(&body, UInt16(min(indices.count, 255)))
        for i in indices.prefix(255) { appendLE(&body, i) }
        return wirePacket(.nack, body: body)
    }

    static func selectDisplay(id: UInt32) -> Data {
        var body: [UInt8] = []
        appendLE(&body, id)
        return wirePacket(.selectDisplay, body: body)
    }

    static func subscribeDisplays(ids: [UInt32]) -> Data {
        var body: [UInt8] = []
        body.append(UInt8(min(ids.count, 255)))
        for id in ids.prefix(255) { appendLE(&body, id) }
        return wirePacket(.subscribeDisplays, body: body)
    }

    static func bye() -> Data { wirePacket(.bye) }

    static func cursorImageAck(imageId: UInt32) -> Data { wirePacket(.cursorImageAck, seq: imageId) }

    static func layoutRestoreAck() -> Data { wirePacket(.layoutRestoreAck) }

    static func displayModeStatusAck(transaction: UInt32) -> Data {
        wirePacket(.displayModeStatusAck, seq: transaction)
    }
}

// MARK: - host→client 解析

enum HostWire {
    /// 解析失败返回 nil（长度不足 / 类型未知 / 字段越界）
    static func parse(_ data: Data) -> HostPacket? {
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data)
        let type = bytes[0]

        switch type {
        case PacketType.welcome.rawValue:
            // [displayId u16][proto u8][codec u8][w u16][h u16][fps u8][controlEnabled u8?]
            guard bytes.count >= 14 else { return nil }
            let controlEnabled = bytes.count < 15 || bytes[14] != 0
            return .welcome(displayId: readU16(bytes, 0), proto: readU8(bytes, 2),
                            codec: readU8(bytes, 3), width: readU16(bytes, 4),
                            height: readU16(bytes, 6), fps: readU8(bytes, 8),
                            controlEnabled: controlEnabled)

        case PacketType.config.rawValue:
            // [displayId u16][codec u8][len u16][Annex-B 参数集]
            guard bytes.count >= 10 else { return nil }
            let len = Int(readU16(bytes, 3))
            guard bytes.count >= 10 + len else { return nil }
            let payload = Data(bytes[10..<(10 + len)])
            return .config(displayId: readU16(bytes, 0), codec: readU8(bytes, 2), paramSets: payload)

        case PacketType.videoFrag.rawValue:
            // [displayId u16][fragIdx u16][fragCount u16][flags u8][payload]
            guard bytes.count > 12 else { return nil }
            let idx = readU16(bytes, 2), count = readU16(bytes, 4)
            // idx ≥ count = FEC 校验片（组号 = idx - count，见 FrameAssembler）。
            // 曾在此处 `idx < count` 一刀切，校验片进不了路由层——FEC 全链路
            // 静默失效（2026-08-29 动画负载实测定位）。上界：数据片 4096，
            // 校验组号 ≤ 数据片/8 = 512。
            guard count < 4096, idx < count + 512 else { return nil }
            let payload = Data(bytes[12..<bytes.count])
            return .videoFragment(displayId: readU16(bytes, 0), frameId: headerSeq(bytes),
                                  fragIdx: idx, fragCount: count,
                                  keyframe: (readU8(bytes, 6) & 1) == 1, payload: payload)

        case PacketType.displays.rawValue:
            guard bytes.count >= 6 else { return nil }
            let count = Int(readU8(bytes, 0))
            var list: [DisplayInfo] = []
            list.reserveCapacity(count)
            var off = 1 // 相对 body 的游标；readU* 内部统一 +5 换算到原始索引
            for _ in 0..<count {
                guard bytes.count >= off + 9 else { return nil }
                let id = readU32(bytes, off)
                let w = readU16(bytes, off + 4)
                let h = readU16(bytes, off + 6)
                let nameLen = Int(readU8(bytes, off + 8))
                guard bytes.count >= off + 9 + nameLen else { return nil }
                let nameBase = 5 + off + 9 // 名字切片必须换算成原始索引
                let nameData = Data(bytes[nameBase..<(nameBase + nameLen)])
                let name = String(data: nameData, encoding: .utf8) ?? ""
                list.append(DisplayInfo(id: id, width: w, height: h, name: name))
                off += 9 + nameLen
            }
            return .displays(list)

        case PacketType.savedLayout.rawValue:
            guard bytes.count >= 5 + LayoutWire.byteCount else { return nil }
            let raw = Array(bytes[5...])
            guard let layout = LayoutWire.decode(base: raw) else { return nil }
            return .savedLayout(layout)

        case PacketType.displayModeStatus.rawValue:
            // [transaction seq u32][status][slot][requestedScale][actualScale]
            guard bytes.count >= 9 else { return nil }
            // [transaction seq][status][slot][requestedScale][actualScale]
            guard let status = DisplayModeStatus(rawValue: readU8(bytes, 0)) else { return nil }
            return .displayModeStatus(transaction: headerSeq(bytes), status: status,
                                      slot: readU8(bytes, 1), requestedScale: readU8(bytes, 2),
                                      effectiveScale: readU8(bytes, 3))

        case PacketType.cursor.rawValue:
            // [displayId u16][x f32][y f32]
            guard bytes.count >= 15 else { return nil }
            return .cursor(displayId: readU16(bytes, 0), x: readF32(bytes, 2), y: readF32(bytes, 6))

        case PacketType.cursorImage.rawValue:
            // [fragIdx u16][fragCount u16][w u16][h u16][hotX i16][hotY i16][BGRA]
            guard bytes.count > 17 else { return nil }
            let hotX = Int16(bitPattern: readU16(bytes, 8))
            let hotY = Int16(bitPattern: readU16(bytes, 10))
            let payload = Data(bytes[17..<bytes.count])
            return .cursorImage(imageId: headerSeq(bytes), index: readU16(bytes, 0),
                                count: readU16(bytes, 2), width: readU16(bytes, 4),
                                height: readU16(bytes, 6), hotX: hotX, hotY: hotY, payload: payload)

        case PacketType.inputAck.rawValue:
            return .inputAck(seq: headerSeq(bytes))

        case PacketType.pong.rawValue:
            // 尾字节 known：老 host 无此字节按 known 处理
            return .pong(known: bytes.count < 6 || bytes[5] != 0)

        default:
            return nil
        }
    }

    /// 公共头的 seq 字段（原始索引 1..5）
    private static func headerSeq(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)
    }
}
