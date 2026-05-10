import Foundation

struct ChromeMigration: BrowserMigrating {
    let source = MigrationSource.chrome

    func profiles() -> [BrowserProfile] {
        MigrationFileSystem.existingDirectories(profileRoots).flatMap { root in
            chromeProfiles(in: root)
        }
    }

    func migrate(profile: BrowserProfile) throws -> BrowserMigrationPayload {
        var payload = BrowserMigrationPayload()
        let decryptor = ChromeDecryptor()

        payload.bookmarks = importBookmarks(from: profile.path)
        payload.history = try importHistory(from: profile.path)

        let credentialImport = try importCredentials(from: profile.path, decryptor: decryptor)
        payload.credentials = credentialImport.credentials
        payload.warnings.append(contentsOf: credentialImport.warnings)

        let cookieImport = try importCookies(from: profile.path, decryptor: decryptor)
        payload.cookies = cookieImport.cookies
        payload.warnings.append(contentsOf: cookieImport.warnings)

        return payload
    }

    private var profileRoots: [URL] {
        [
            MigrationFileSystem.homeDirectory.appendingPathComponent("Library/Application Support/Google/Chrome"),
            MigrationFileSystem.homeDirectory.appendingPathComponent("Library/Application Support/Chromium")
        ]
    }

    private func chromeProfiles(in root: URL) -> [BrowserProfile] {
        let profileNames = profileDisplayNames(in: root)
        let fileManager = FileManager.default
        let candidates: [URL]

        if let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates = contents.filter { url in
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else {
                    return false
                }

                return url.lastPathComponent == "Default"
                    || url.lastPathComponent.hasPrefix("Profile ")
                    || fileManager.fileExists(atPath: url.appendingPathComponent("Preferences").path)
            }
        } else {
            candidates = []
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Preferences").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { profileURL in
                BrowserProfile(
                    source: source,
                    name: profileNames[profileURL.lastPathComponent] ?? defaultProfileName(profileURL.lastPathComponent),
                    path: profileURL
                )
            }
    }

    private func profileDisplayNames(in root: URL) -> [String: String] {
        let localStateURL = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return [:]
        }

        var names: [String: String] = [:]
        for (directory, rawInfo) in infoCache {
            guard let info = rawInfo as? [String: Any],
                  let name = info["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            names[directory] = name
        }
        return names
    }

    private func defaultProfileName(_ directoryName: String) -> String {
        directoryName == "Default" ? "Default Profile" : directoryName
    }

    private func importBookmarks(from profileURL: URL) -> [ImportedBookmark] {
        let bookmarksURL = profileURL.appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: bookmarksURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else {
            return []
        }

        var bookmarks: [ImportedBookmark] = []
        for value in roots.values {
            collectChromeBookmarks(value, into: &bookmarks)
        }
        return bookmarks
    }

    private func collectChromeBookmarks(_ node: Any, into bookmarks: inout [ImportedBookmark]) {
        guard let node = node as? [String: Any] else { return }

        if let type = node["type"] as? String,
           type == "url",
           let rawURL = node["url"] as? String,
           rawURL.hasPrefix("http") {
            let title = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.append(ImportedBookmark(
                title: title?.isEmpty == false ? title! : rawURL,
                url: rawURL
            ))
        }

        if let children = node["children"] as? [Any] {
            for child in children {
                collectChromeBookmarks(child, into: &bookmarks)
            }
        }
    }

    private func importHistory(from profileURL: URL) throws -> [ImportedHistoryEntry] {
        let historyURL = profileURL.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }

        let rows = try SQLiteJSON.query(historyURL, sql: """
        SELECT IFNULL(title, url) AS title,
               url,
               visit_count,
               last_visit_time
        FROM urls
        WHERE url LIKE 'http%'
        ORDER BY last_visit_time DESC
        LIMIT 5000;
        """, as: ChromeHistoryRow.self)

        return rows.map {
            ImportedHistoryEntry(
                title: $0.title.isEmpty ? $0.url : $0.title,
                url: $0.url,
                visitCount: $0.visit_count,
                lastVisitedAt: .chromeDate(microsecondsSince1601: $0.last_visit_time)
            )
        }
    }

    private func importCredentials(
        from profileURL: URL,
        decryptor: ChromeDecryptor
    ) throws -> (credentials: [BrowserCredential], warnings: [String]) {
        let loginDataURL = profileURL.appendingPathComponent("Login Data")
        guard FileManager.default.fileExists(atPath: loginDataURL.path) else { return ([], []) }

        let rows = try SQLiteJSON.query(loginDataURL, sql: """
        SELECT origin_url,
               action_url,
               username_value,
               hex(password_value) AS password_hex
        FROM logins
        WHERE blacklisted_by_user = 0
          AND username_value <> ''
          AND password_value IS NOT NULL;
        """, as: ChromePasswordRow.self)

        var credentials: [BrowserCredential] = []
        var failedDecryptions = 0

        for row in rows {
            guard let password = decryptor.decrypt(hexEncodedValue: row.password_hex), !password.isEmpty else {
                failedDecryptions += 1
                continue
            }

            credentials.append(BrowserCredential(
                originURL: row.origin_url,
                actionURL: row.action_url,
                username: row.username_value,
                password: password
            ))
        }

        var warnings: [String] = []
        if failedDecryptions > 0 {
            warnings.append("\(failedDecryptions) Chrome passwords could not be decrypted from the local profile.")
        }
        return (credentials, warnings)
    }

    private func importCookies(
        from profileURL: URL,
        decryptor: ChromeDecryptor
    ) throws -> (cookies: [BrowserCookie], warnings: [String]) {
        let cookieCandidates = [
            profileURL.appendingPathComponent("Network/Cookies"),
            profileURL.appendingPathComponent("Cookies")
        ]
        guard let cookiesURL = cookieCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return ([], [])
        }

        let rows = try SQLiteJSON.query(cookiesURL, sql: """
        SELECT host_key,
               name,
               value,
               hex(encrypted_value) AS encrypted_value_hex,
               path,
               expires_utc,
               is_secure,
               is_httponly
        FROM cookies
        WHERE host_key <> ''
          AND name <> '';
        """, as: ChromeCookieRow.self)

        var cookies: [BrowserCookie] = []
        var failedDecryptions = 0

        for row in rows {
            let decryptedValue: String?
            if !row.value.isEmpty {
                decryptedValue = row.value
            } else {
                decryptedValue = decryptor.decrypt(hexEncodedValue: row.encrypted_value_hex)
            }

            guard let value = decryptedValue else {
                failedDecryptions += 1
                continue
            }

            cookies.append(BrowserCookie(
                domain: row.host_key,
                name: row.name,
                value: value,
                path: row.path.isEmpty ? "/" : row.path,
                expiresAt: .chromeDate(microsecondsSince1601: row.expires_utc),
                isSecure: row.is_secure != 0,
                isHTTPOnly: row.is_httponly != 0
            ))
        }

        var warnings: [String] = []
        if failedDecryptions > 0 {
            warnings.append("\(failedDecryptions) Chrome cookies could not be decrypted from the local profile.")
        }
        return (cookies, warnings)
    }
}

private struct ChromeHistoryRow: Decodable {
    var title: String
    var url: String
    var visit_count: Int
    var last_visit_time: Int64
}

private struct ChromePasswordRow: Decodable {
    var origin_url: String
    var action_url: String
    var username_value: String
    var password_hex: String
}

private struct ChromeCookieRow: Decodable {
    var host_key: String
    var name: String
    var value: String
    var encrypted_value_hex: String
    var path: String
    var expires_utc: Int64
    var is_secure: Int
    var is_httponly: Int
}

private final class ChromeDecryptor {
    private let key: Data?
    private let iv = Data(repeating: 0x20, count: 16)

    init() {
        key = Self.deriveChromeKey()
    }

    func decrypt(hexEncodedValue: String) -> String? {
        guard let key,
              let encryptedValue = Data(hexEncoded: hexEncodedValue),
              !encryptedValue.isEmpty else {
            return nil
        }

        let ciphertext: Data
        if encryptedValue.starts(with: Data("v10".utf8)) || encryptedValue.starts(with: Data("v11".utf8)) {
            ciphertext = encryptedValue.dropFirst(3)
        } else {
            ciphertext = encryptedValue
        }

        guard !ciphertext.isEmpty,
              let decrypted = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: [
                    "enc",
                    "-d",
                    "-aes-128-cbc",
                    "-K", key.hexEncodedString,
                    "-iv", iv.hexEncodedString
                ],
                input: ciphertext
              ) else {
            return nil
        }

        return decrypted.stdout
    }

    private static func deriveChromeKey() -> Data? {
        guard let password = chromeSafeStoragePassword(), !password.isEmpty else {
            return nil
        }

        return PasswordKeyDerivation.pbkdf2SHA1(
            password: Data(password.utf8),
            salt: Data("saltysalt".utf8),
            iterations: 1003,
            keyByteCount: 16
        )
    }

    private static func chromeSafeStoragePassword() -> String? {
        for serviceName in ["Chrome Safe Storage", "Chromium Safe Storage"] {
            guard let output = try? ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-w", "-s", serviceName]
            ) else {
                continue
            }

            let password = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty {
                return password
            }
        }

        return nil
    }
}
