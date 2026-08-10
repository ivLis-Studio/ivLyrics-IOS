import Foundation
import Security

final class SecureStringStore: @unchecked Sendable {
    static let shared = SecureStringStore(service: "kr.ivlis.ivlyrics.secure-settings")

    private let service: String

    init(service: String) {
        self.service = service
    }

    func string(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func migratedString(forKey key: String, legacyDefaults: UserDefaults) -> String? {
        if let stored = string(forKey: key) {
            legacyDefaults.removeObject(forKey: key)
            return stored
        }
        guard let legacy = legacyDefaults.string(forKey: key) else { return nil }
        if set(legacy, forKey: key) {
            legacyDefaults.removeObject(forKey: key)
        }
        return legacy
    }

    @discardableResult
    func set(_ value: String?, forKey key: String) -> Bool {
        guard let value, !value.isEmpty else {
            return remove(forKey: key)
        }
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove(forKey key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
