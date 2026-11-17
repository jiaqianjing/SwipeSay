import Foundation
import Security

/// Small wrapper over the login keychain (generic passwords). Values are cached in memory
/// after the first read so the keychain is touched as little as possible.
enum Keychain {
    private static let service = "com.kenjia.swipesay"
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[account] { return cached.isEmpty ? nil : cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            cache[account] = ""
            return nil
        }
        cache[account] = value
        return value
    }

    static func set(_ value: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            cache[account] = ""
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
        cache[account] = value
    }
}
