import Foundation
import Security

// Минимальная обёртка над Keychain для хранения PIN-кода
enum Keychain {
    @discardableResult
    static func set(
        _ data: Data,
        service: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> OSStatus {
        delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func get(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
