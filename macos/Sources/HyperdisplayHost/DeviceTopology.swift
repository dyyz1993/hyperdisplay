import Foundation

/// 一台平板的每种显示布局都是一套独立的 macOS 显示器档案。
///
/// 布局决定 EDID 身份和位置存储的命名空间；尺寸档位、分割比例不决定身份。这样用户
/// 在同一布局内调大/调小或拖动分隔条时，macOS 仍会把它认作原来的那组显示器；切换到
/// 另一种拓扑时，则不会污染原布局的窗口归属和桌面编排。
enum DeviceTopology: UInt8, CaseIterable, Hashable {
    case single = 0
    case splitLeftRight = 1
    case splitTopBottom = 2
    case sideBySide = 3
    case pictureInPicture = 4

    init(layoutKind: UInt8?, requestedScreenCount: Int) {
        if let layoutKind, let known = Self(rawValue: layoutKind) {
            self = known
        } else {
            // 兼容不带布局快照的旧客户端：它们只有一块屏时沿用历史单屏身份；有多块
            // 屏时归入左右分屏档案，绝不与单屏共用 slot 0 的位置记录。
            self = requestedScreenCount > 1 ? .splitLeftRight : .single
        }
    }

    var persistenceComponent: String { String(rawValue) }

    var displayName: String {
        switch self {
        case .single: return "单屏"
        case .splitLeftRight: return "左右分屏"
        case .splitTopBottom: return "上下分屏"
        case .sideBySide: return "主屏侧边"
        case .pictureInPicture: return "画中画"
        }
    }
}

struct DeviceTopologyProfileKey: Hashable {
    let deviceId: UInt32
    let topology: DeviceTopology
}

enum DeviceTopologyIdentity {
    /// 单屏保持旧版本的 EDID，避免现有用户的单屏桌面被当作新显示器。其余布局使用
    /// 不同且稳定的 product/serial 组合，因而彼此都能独立恢复 macOS 编排。
    static func edid(deviceId: UInt32, topology: DeviceTopology, slot: Int) -> (productID: UInt32, serial: UInt32) {
        let safeSlot = UInt32(clamping: max(0, slot)) & 0x0F
        if topology == .single && safeSlot == 0 {
            return (productID: 0x0001, serial: 1000 + (deviceId & 0xFFFF))
        }

        let group = UInt32(topology.rawValue) & 0x0F
        let serial = 0x8000_0000
            | ((deviceId & 0x000F_FFFF) << 8)
            | (group << 4)
            | safeSlot
        let productID = 0x0100 + (group << 4) + safeSlot
        return (productID: productID, serial: serial)
    }
}
