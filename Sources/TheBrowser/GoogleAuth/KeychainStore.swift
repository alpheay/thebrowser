import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case encoding

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "Keychain error \(code) (\(Self.describe(code)))"
        case .encoding:
            return "Keychain encoding failed."
        }
    }

    private static func describe(_ code: OSStatus) -> String {
        switch code {
        case errSecSuccess: return "success"
        case errSecMissingEntitlement: return "missing entitlement — try a code-signed .app bundle instead of `swift run`"
        case errSecNotAvailable: return "keychain not available"
        case errSecParam: return "invalid parameter"
        case errSecInteractionNotAllowed: return "interaction not allowed"
        case errSecAuthFailed: return "auth failed"
        case errSecDuplicateItem: return "duplicate item"
        case errSecItemNotFound: return "item not found"
        case errSecDecode: return "decode failed"
        case errSecAllocate: return "allocation failed"
        case errSecUnimplemented: return "unimplemented"
        default:
            if let message = SecCopyErrorMessageString(code, nil) as String? {
                return message
            }
            return "unknown"
        }
    }
}

enum KeychainStore {
    /// Default keychain service. Predates the Discord integration — kept as
    /// the default so Google tokens written with the old API path continue
    /// to resolve. New callers pass an explicit `service:` (e.g. Discord).
    static let serviceName = "com.thebrowser.googleAccount"

    /// All queries try the modern "data protection" keychain first because
    /// on macOS the legacy file-backed keychain gates each item by the
    /// calling binary's code signature — every unsigned/ad-hoc-signed
    /// build triggers a login-password prompt. The data protection
    /// keychain uses iOS-style access-group semantics derived from the
    /// app's signing identity instead, which does not prompt.
    ///
    /// Downside: DPK requires the binary to have keychain entitlements
    /// (Team ID + access groups), which `swift run` builds don't have.
    /// When DPK refuses with an entitlement/availability error we
    /// transparently fall back to the legacy keychain so dev builds still
    /// work.
    private static func baseQuery(account: String, service: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// OSStatus values that indicate DPK isn't usable in this process —
    /// retry the call against the legacy keychain.
    private static func shouldFallbackToLegacy(_ status: OSStatus) -> Bool {
        switch status {
        case errSecMissingEntitlement, errSecNotAvailable, errSecParam:
            return true
        default:
            return false
        }
    }

    static func save(_ data: Data, account: String, service: String = serviceName) throws {
        do {
            try saveCore(data: data, account: account, service: service, useDataProtection: true)
        } catch KeychainError.status(let s) where shouldFallbackToLegacy(s) {
            try saveCore(data: data, account: account, service: service, useDataProtection: false)
        }
    }

    private static func saveCore(data: Data, account: String, service: String, useDataProtection: Bool) throws {
        let query = baseQuery(account: account, service: service, useDataProtection: useDataProtection)

        // `kSecAttrAccessible` is only honored on `SecItemAdd`; passing it
        // to `SecItemUpdate` is fine on iOS but can cause `errSecParam` on
        // macOS depending on OS version. Limit it to the insert path.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
        if let data = loadCore(account: account, service: service, useDataProtection: true) {
            return data
        }
        return loadCore(account: account, service: service, useDataProtection: false)
    }

    private static func loadCore(account: String, service: String, useDataProtection: Bool) -> Data? {
        var query = baseQuery(account: account, service: service, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

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
        // Wipe from both backends so a fallback save during sign-out cleans
        // up everywhere the token might be lingering.
        let modern = SecItemDelete(baseQuery(account: account, service: service, useDataProtection: true) as CFDictionary)
        let legacy = SecItemDelete(baseQuery(account: account, service: service, useDataProtection: false) as CFDictionary)
        let success: (OSStatus) -> Bool = { $0 == errSecSuccess || $0 == errSecItemNotFound }
        return success(modern) || success(legacy)
    }
}
