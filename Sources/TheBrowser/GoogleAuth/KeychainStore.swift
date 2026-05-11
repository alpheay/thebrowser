import Foundation
import Security

enum KeychainError: Error {
    case status(OSStatus)
    case encoding
}

enum KeychainStore {
    /// Default keychain service. Predates the Discord integration — kept as
    /// the default so Google tokens written with the old API path continue
    /// to resolve. New callers pass an explicit `service:` (e.g. Discord).
    static let serviceName = "com.thebrowser.googleAccount"

    static func save(_ data: Data, account: String, service: String = serviceName) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.status(addStatus)
            }
            return
        }

        if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func saveString(_ value: String, account: String, service: String = serviceName) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        try save(data, account: account, service: service)
    }

    static func load(account: String, service: String = serviceName) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    static func loadString(account: String, service: String = serviceName) -> String? {
        guard let data = load(account: account, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String, service: String = serviceName) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
