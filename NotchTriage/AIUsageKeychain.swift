import Foundation
import Security

/// Separate service per application bundle; never persist credentials in preferences or reports.
enum AIUsageKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "NotchTriage") + ".ai-usage" }
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func read(_ id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ secret: String, for id: String) throws {
        let q = query(id)
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AIUsageError.keychain }
        } else if status != errSecSuccess { throw AIUsageError.keychain }
    }
    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

enum AIUsageError: LocalizedError {
    case keychain, noKey, noData, invalidResponse, http(Int), configuration(String)
    var errorDescription: String? {
        switch self {
        case .keychain: return "无法访问钥匙串；凭证未保存"
        case .noKey: return "未配置 API Key 或 Token"
        case .noData: return "平台暂未提供可显示的用量数据"
        case .invalidResponse: return "平台返回格式已变化，请更新应用或检查账户类型"
        case .http(let code):
            switch code {
            case 401: return "凭证无效或已过期（401）"
            case 403: return "凭证权限不足或账户不支持查询（403）"
            case 429: return "平台限制查询频率，请稍后重试（429）"
            default: return "用量服务请求失败（HTTP \(code)）"
            }
        case .configuration(let message): return message
        }
    }
}
