import Foundation
import CryptoKit
import UIKit

/// 零点击设备档案：HELLO 的 deviceId / fingerprint / 设备名。
/// 安卓端用 ANDROID_ID 做跨卸载指纹；iOS 等效物是 Keychain 里存一个随机 UUID——
/// 卸载重装不丢，与 host 的「指纹命中恢复屏幕槽位」语义一致。
enum DeviceIdentity {

    private static let defaults = UserDefaults.standard

    /// 旧版安装内 ID：保证普通升级绝不改 EDID 归并键；新安装随机生成本地会话编号
    static func loadOrCreateDeviceId() -> UInt32 {
        let existing = defaults.integer(forKey: "hd.deviceId")
        if existing != 0 { return UInt32(clamping: existing) }
        let fresh = Int.random(in: 1..<Int(Int32.max))
        defaults.set(fresh, forKey: "hd.deviceId")
        return UInt32(fresh)
    }

    /// Keychain UUID → SHA-256 前 64 位小端。原始 UUID 从不离开本机。
    static func loadDeviceFingerprint() -> UInt64 {
        let uuid = loadOrCreateKeychainUUID()
        let digest = SHA256.hash(data: Data("com.hyperdisplay.client/device-identity/v1:\(uuid)".utf8))
        let bytes = Array(digest.prefix(8))
        var value: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) { value = (value << 8) | UInt64(bytes[i]) }
        // 0 是协议中「旧客户端未提供指纹」保留值，极低概率碰到时改成 1
        return value == 0 ? 1 : value
    }

    static func deviceDisplayName() -> String {
        let raw = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "iPad" : String(raw.prefix(48))
    }

    // MARK: - Keychain

    private static let service = "com.hyperdisplay.client"
    private static let account = "deviceFingerprint"

    private static func loadOrCreateKeychainUUID() -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = Data(fresh.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // 已存在但首查失败（极少见）：忽略，用新值会话内兜底
            NSLog("DeviceIdentity: keychain duplicate, regenerate in-memory")
        } else if addStatus != errSecSuccess {
            NSLog("DeviceIdentity: keychain add failed %d", addStatus)
        }
        return fresh
    }
}
