import Darwin
import Foundation

struct FirefoxMigration: BrowserMigrating {
    let source = MigrationSource.firefox

    func profiles() -> [BrowserProfile] {
        MigrationFileSystem.existingDirectories(profileRoots).flatMap { root in
            firefoxProfiles(in: root)
        }
    }

    func migrate(profile: BrowserProfile) throws -> BrowserMigrationPayload {
        var payload = BrowserMigrationPayload()
        payload.bookmarks = try importBookmarks(from: profile.path)
        payload.history = try importHistory(from: profile.path)
        payload.cookies = try importCookies(from: profile.path)

        let credentialImport = importCredentials(from: profile.path)
        payload.credentials = credentialImport.credentials
        payload.warnings.append(contentsOf: credentialImport.warnings)

        return payload
    }

    private var profileRoots: [URL] {
        [
            MigrationFileSystem.homeDirectory.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        ]
    }

    private func firefoxProfiles(in root: URL) -> [BrowserProfile] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else {
                    return false
                }
                return FileManager.default.fileExists(atPath: url.appendingPathComponent("prefs.js").path)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { profileURL in
                BrowserProfile(
                    source: source,
                    name: firefoxProfileName(profileURL),
                    path: profileURL
                )
            }
    }

    private func firefoxProfileName(_ profileURL: URL) -> String {
        let name = profileURL.lastPathComponent
        if let dotIndex = name.firstIndex(of: ".") {
            return String(name[name.index(after: dotIndex)...]).replacingOccurrences(of: "-", with: " ").capitalized
        }
        return name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func importBookmarks(from profileURL: URL) throws -> [ImportedBookmark] {
        let placesURL = profileURL.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: placesURL.path) else { return [] }

        let rows = try SQLiteJSON.query(placesURL, sql: """
        SELECT IFNULL(b.title, p.title) AS title,
               p.url
        FROM moz_bookmarks b
        JOIN moz_places p ON b.fk = p.id
        WHERE b.type = 1
          AND p.url LIKE 'http%'
        ORDER BY b.dateAdded DESC
        LIMIT 5000;
        """, as: FirefoxBookmarkRow.self)

        return rows.map {
            ImportedBookmark(
                title: $0.title?.isEmpty == false ? $0.title! : $0.url,
                url: $0.url
            )
        }
    }

    private func importHistory(from profileURL: URL) throws -> [ImportedHistoryEntry] {
        let placesURL = profileURL.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: placesURL.path) else { return [] }

        let rows = try SQLiteJSON.query(placesURL, sql: """
        SELECT IFNULL(title, url) AS title,
               url,
               visit_count,
               last_visit_date
        FROM moz_places
        WHERE url LIKE 'http%'
          AND visit_count > 0
        ORDER BY last_visit_date DESC
        LIMIT 5000;
        """, as: FirefoxHistoryRow.self)

        return rows.map {
            ImportedHistoryEntry(
                title: $0.title.isEmpty ? $0.url : $0.title,
                url: $0.url,
                visitCount: $0.visit_count,
                lastVisitedAt: .firefoxDate(microsecondsSince1970: $0.last_visit_date)
            )
        }
    }

    private func importCookies(from profileURL: URL) throws -> [BrowserCookie] {
        let cookiesURL = profileURL.appendingPathComponent("cookies.sqlite")
        guard FileManager.default.fileExists(atPath: cookiesURL.path) else { return [] }

        let rows = try SQLiteJSON.query(cookiesURL, sql: """
        SELECT host,
               name,
               value,
               path,
               expiry,
               isSecure,
               isHttpOnly
        FROM moz_cookies
        WHERE host <> ''
          AND name <> '';
        """, as: FirefoxCookieRow.self)

        return rows.map {
            BrowserCookie(
                domain: $0.host,
                name: $0.name,
                value: $0.value,
                path: $0.path.isEmpty ? "/" : $0.path,
                expiresAt: $0.expiry > 0 ? Date(timeIntervalSince1970: TimeInterval($0.expiry)) : nil,
                isSecure: $0.isSecure != 0,
                isHTTPOnly: $0.isHttpOnly != 0
            )
        }
    }

    private func importCredentials(from profileURL: URL) -> (credentials: [BrowserCredential], warnings: [String]) {
        let loginsURL = profileURL.appendingPathComponent("logins.json")
        guard let data = try? Data(contentsOf: loginsURL),
              let loginFile = try? JSONDecoder().decode(FirefoxLoginFile.self, from: data) else {
            return ([], [])
        }

        guard !loginFile.logins.isEmpty else { return ([], []) }

        guard let decryptor = try? FirefoxNSSDecryptor(profileURL: profileURL) else {
            return ([], ["Firefox passwords are encrypted; install or unlock Firefox so TheBrowser can ask NSS to decrypt them."])
        }

        var credentials: [BrowserCredential] = []
        var failedDecryptions = 0

        for login in loginFile.logins {
            guard let username = decryptor.decrypt(login.encryptedUsername),
                  let password = decryptor.decrypt(login.encryptedPassword),
                  !username.isEmpty,
                  !password.isEmpty else {
                failedDecryptions += 1
                continue
            }

            credentials.append(BrowserCredential(
                originURL: login.hostname,
                actionURL: login.formSubmitURL ?? login.hostname,
                username: username,
                password: password
            ))
        }

        var warnings: [String] = []
        if failedDecryptions > 0 {
            warnings.append("\(failedDecryptions) Firefox passwords could not be decrypted from the local profile.")
        }
        return (credentials, warnings)
    }
}

private struct FirefoxBookmarkRow: Decodable {
    var title: String?
    var url: String
}

private struct FirefoxHistoryRow: Decodable {
    var title: String
    var url: String
    var visit_count: Int
    var last_visit_date: Int64?
}

private struct FirefoxCookieRow: Decodable {
    var host: String
    var name: String
    var value: String
    var path: String
    var expiry: Int64
    var isSecure: Int
    var isHttpOnly: Int
}

private struct FirefoxLoginFile: Decodable {
    var logins: [FirefoxLogin]
}

private struct FirefoxLogin: Decodable {
    var hostname: String
    var formSubmitURL: String?
    var encryptedUsername: String
    var encryptedPassword: String
}

private final class FirefoxNSSDecryptor {
    private struct SECItem {
        var type: Int32
        var data: UnsafeMutablePointer<UInt8>?
        var len: UInt32
    }

    private typealias NSSInit = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias NSSShutdown = @convention(c) () -> Int32
    private typealias PK11SDRDecrypt = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias SECITEMFreeItem = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    private let handle: UnsafeMutableRawPointer
    private let shutdown: NSSShutdown
    private let decryptFunction: PK11SDRDecrypt
    private let freeItem: SECITEMFreeItem

    init(profileURL: URL) throws {
        guard let libraryURL = Self.nssLibraryURL() else {
            throw MigrationError.decryptionUnavailable("Firefox NSS library was not found.")
        }

        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_GLOBAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "Firefox NSS could not be loaded."
            throw MigrationError.decryptionUnavailable(detail)
        }

        self.handle = handle

        let initFunction: NSSInit = try Self.symbol("NSS_Init", in: handle)
        shutdown = try Self.symbol("NSS_Shutdown", in: handle)
        decryptFunction = try Self.symbol("PK11SDR_Decrypt", in: handle)
        freeItem = try Self.symbol("SECITEM_FreeItem", in: handle)

        let profilePath = "sql:\(profileURL.path)"
        let status = profilePath.withCString { initFunction($0) }
        guard status == 0 else {
            _ = shutdown()
            dlclose(handle)
            throw MigrationError.decryptionUnavailable("Firefox profile could not be opened by NSS.")
        }
    }

    deinit {
        _ = shutdown()
        dlclose(handle)
    }

    func decrypt(_ base64Value: String) -> String? {
        guard let encryptedData = Data(base64Encoded: base64Value) else { return nil }

        return encryptedData.withUnsafeBytes { encryptedPointer -> String? in
            guard let baseAddress = encryptedPointer.baseAddress else { return nil }

            var input = SECItem(
                type: 0,
                data: UnsafeMutableRawPointer(mutating: baseAddress).assumingMemoryBound(to: UInt8.self),
                len: UInt32(encryptedData.count)
            )
            var output = SECItem(type: 0, data: nil, len: 0)

            let status = withUnsafeMutablePointer(to: &input) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    decryptFunction(
                        UnsafeMutableRawPointer(inputPointer),
                        UnsafeMutableRawPointer(outputPointer),
                        nil
                    )
                }
            }

            guard status == 0, let outputData = output.data, output.len > 0 else {
                return nil
            }

            let data = Data(bytes: outputData, count: Int(output.len))
            withUnsafeMutablePointer(to: &output) { outputPointer in
                freeItem(UnsafeMutableRawPointer(outputPointer), 0)
            }
            return String(data: data, encoding: .utf8)
        }
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw MigrationError.decryptionUnavailable("\(name) is not available in Firefox NSS.")
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func nssLibraryURL() -> URL? {
        let candidates = [
            "/Applications/Firefox.app/Contents/MacOS/libnss3.dylib",
            "/Applications/Firefox Developer Edition.app/Contents/MacOS/libnss3.dylib",
            "\(MigrationFileSystem.homeDirectory.path)/Applications/Firefox.app/Contents/MacOS/libnss3.dylib"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
