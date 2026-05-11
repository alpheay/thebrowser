import Foundation
import Security

enum KeychainError: Error {
    case status(OSStatus)
    case encoding
}

enum KeychainStore {
    static let serviceName = "com.thebrowser.googleAccount"

    /// All queries opt into the modern "data protection" keychain. On macOS
    /// the legacy file-backed keychain gates each item by the calling
    /// binary's code signature, so every unsigned/ad-hoc-signed build
    /// triggers a login-password prompt. The data protection keychain uses
    /// iOS-style access-group semantics derived from the app's signing
    /// identity instead, which does not prompt.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)

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

    static func saveString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        try save(data, account: account)
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    static func loadString(account: String) -> String? {
        guard let data = load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
