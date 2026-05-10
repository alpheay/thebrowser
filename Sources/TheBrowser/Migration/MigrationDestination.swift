import Foundation
import Security
@preconcurrency import WebKit

enum MigrationDestination {
    static func install(payload: BrowserMigrationPayload, source: MigrationSource) async -> (counts: MigrationCounts, warnings: [String]) {
        var warnings = payload.warnings
        let cookiesImported = await importCookies(payload.cookies)
        let passwordsImported = importCredentials(payload.credentials, source: source)

        if passwordsImported.failed > 0 {
            warnings.append("\(passwordsImported.failed) saved passwords could not be written to Keychain.")
        }

        let accounts = Set(payload.cookies.map { normalizedDomain($0.domain) }).count
        let counts = MigrationCounts(
            accounts: accounts,
            passwords: passwordsImported.succeeded,
            cookies: cookiesImported,
            bookmarks: payload.bookmarks.count,
            history: payload.history.count
        )

        return (counts, warnings)
    }

    @MainActor
    private static func importCookies(_ cookies: [BrowserCookie]) async -> Int {
        var imported = 0
        let store = WKWebsiteDataStore.default().httpCookieStore

        for sourceCookie in cookies {
            guard let cookie = sourceCookie.httpCookie else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
            imported += 1
        }

        return imported
    }

    private static func importCredentials(
        _ credentials: [BrowserCredential],
        source: MigrationSource
    ) -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0

        for credential in credentials {
            do {
                try KeychainPasswordImporter.save(credential, source: source)
                succeeded += 1
            } catch {
                failed += 1
            }
        }

        return (succeeded, failed)
    }

    private static func normalizedDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

private extension BrowserCookie {
    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .name: name,
            .value: value
        ]

        if isSecure {
            properties[.secure] = "TRUE"
        }

        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        if let expiresAt {
            properties[.expires] = expiresAt
        }

        return HTTPCookie(properties: properties)
    }
}

private enum KeychainPasswordImporter {
    static func save(_ credential: BrowserCredential, source: MigrationSource) throws {
        guard !credential.username.isEmpty, !credential.password.isEmpty else { return }
        guard let destination = CredentialDestination(credential: credential) else {
            throw MigrationError.keychainFailed("Missing credential host")
        }

        let passwordData = Data(credential.password.utf8)
        let query = baseQuery(destination: destination, account: credential.username)
        var addQuery = query
        addQuery[kSecValueData as String] = passwordData
        addQuery[kSecAttrLabel as String] = "TheBrowser imported \(source.displayName) password"
        addQuery[kSecAttrComment as String] = "Imported by TheBrowser from \(source.displayName)."

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: passwordData,
                    kSecAttrComment as String: "Updated by TheBrowser from \(source.displayName)."
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw MigrationError.keychainFailed(SecCopyErrorMessageString(updateStatus, nil) as String? ?? "Duplicate update failed")
            }
            return
        }

        throw MigrationError.keychainFailed(SecCopyErrorMessageString(addStatus, nil) as String? ?? "Unknown Keychain error")
    }

    private static func baseQuery(destination: CredentialDestination, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: destination.host,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: destination.secProtocol
        ]

        if !destination.path.isEmpty {
            query[kSecAttrPath as String] = destination.path
        }

        return query
    }
}

private struct CredentialDestination {
    var host: String
    var path: String
    var secProtocol: CFString

    init?(credential: BrowserCredential) {
        let rawURL = credential.actionURL.isEmpty ? credential.originURL : credential.actionURL
        guard let url = URL(string: rawURL), let host = url.host(percentEncoded: false) else {
            return nil
        }

        self.host = host
        path = url.path
        secProtocol = url.scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS
    }
}
