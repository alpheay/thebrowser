import CryptoKit
import Foundation
import SQLite3

/// One network observation emitted by the injected content script.
///
/// WKWebView does not expose a public HAR stream. These rows are best-effort
/// content-script observations: fetch/XHR wrappers, plus Resource Timing for
/// subresources the wrappers cannot see. They are not complete packet capture.
struct PageArchiveNetworkEvent: Equatable, Sendable {
    var timestamp: Date
    var pageURL: String?
    var method: String
    var url: String
    var status: Int?
    var type: String
    var requestHeaders: [String: String]
    var responseHeaders: [String: String]
    var requestBody: String?
    var responseBody: String?
    var durationMS: Double?

    init(
        timestamp: Date = Date(),
        pageURL: String? = nil,
        method: String = "GET",
        url: String,
        status: Int? = nil,
        type: String = "",
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBody: String? = nil,
        responseBody: String? = nil,
        durationMS: Double? = nil
    ) {
        self.timestamp = timestamp
        self.pageURL = pageURL
        self.method = method
        self.url = url
        self.status = status
        self.type = type
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.durationMS = durationMS
    }
}

struct PageArchiveVisitCapture: Sendable {
    var url: URL
    var title: String
    var timestamp: Date
    var domData: Data
    var screenshotData: Data
    var networkEvents: [PageArchiveNetworkEvent]

    init(
        url: URL,
        title: String,
        timestamp: Date = Date(),
        domHTML: String,
        screenshotData: Data,
        networkEvents: [PageArchiveNetworkEvent] = []
    ) {
        self.url = url
        self.title = title
        self.timestamp = timestamp
        self.domData = Data(domHTML.utf8)
        self.screenshotData = screenshotData
        self.networkEvents = networkEvents
    }

    init(
        url: URL,
        title: String,
        timestamp: Date = Date(),
        domData: Data,
        screenshotData: Data,
        networkEvents: [PageArchiveNetworkEvent] = []
    ) {
        self.url = url
        self.title = title
        self.timestamp = timestamp
        self.domData = domData
        self.screenshotData = screenshotData
        self.networkEvents = networkEvents
    }
}

struct PageArchiveVisit: Equatable, Sendable {
    var id: Int64
    var url: String
    var title: String
    var timestamp: Date
    var domBlobHash: String
    var screenshotBlobHash: String
    var networkLogID: Int64?
    var networkLogCount: Int
}

struct PageArchiveNetworkLogEntry: Equatable, Sendable {
    var id: Int64
    var visitID: Int64
    var timestamp: Date
    var method: String
    var url: String
    var status: Int?
    var type: String
    var requestHeaders: [String: String]
    var responseHeaders: [String: String]
    var bodyBlobHash: String?
    var body: String?
    var durationMS: Double?
}

struct PageArchiveVisitDetails: Equatable, Sendable {
    var visit: PageArchiveVisit
    var domHTML: String
    var screenshotURL: URL
    var networkLog: [PageArchiveNetworkLogEntry]
}

/// Local, content-addressed archive of rendered pages and observed network
/// requests. Uses raw sqlite3 to match the existing history/clipboard stores
/// and keeps all access on the main actor for one-handle simplicity.
@MainActor
final class PageArchive {
    static let shared = PageArchive()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("TheBrowser", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
    }()

    nonisolated static let defaultMaxArchiveSizeBytes: Int64 = 5 * 1024 * 1024 * 1024
    nonisolated static let defaultDenylist = [
        "americanexpress.com",
        "anthem.com",
        "aetna.com",
        "bankofamerica.com",
        "capitalone.com",
        "chase.com",
        "cigna.com",
        "citibank.com",
        "discover.com",
        "healthcare.gov",
        "humana.com",
        "kaiserpermanente.org",
        "kp.org",
        "mychart.com",
        "paypal.com",
        "uhc.com",
        "wellsfargo.com"
    ]

    private let rootURL: URL
    private let databaseURL: URL
    private let maxArchiveSizeBytes: Int64?
    nonisolated(unsafe) private var db: OpaquePointer?

    init(
        rootURL: URL = PageArchive.rootURL,
        maxArchiveSizeBytes: Int64? = nil
    ) {
        self.rootURL = rootURL
        self.databaseURL = rootURL.appendingPathComponent("index.sqlite")
        self.maxArchiveSizeBytes = maxArchiveSizeBytes
        try? open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    @discardableResult
    func record(visit capture: PageArchiveVisitCapture) -> PageArchiveVisit? {
        guard let db, shouldArchive(url: capture.url) else { return nil }
        guard let domHash = storeBlob(capture.domData, now: capture.timestamp),
              let screenshotHash = storeBlob(capture.screenshotData, now: capture.timestamp) else {
            return nil
        }

        let timestamp = Self.iso8601Formatter.string(from: capture.timestamp)
        exec("BEGIN IMMEDIATE TRANSACTION;")
        var didCommit = false
        defer {
            if !didCommit {
                exec("ROLLBACK;")
            }
        }

        let sql = """
        INSERT INTO visits
            (url, title, ts, dom_blob_hash, screenshot_blob_hash, network_log_id, last_accessed_ts)
        VALUES (?, ?, ?, ?, ?, NULL, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare insert visit")
            exec("ROLLBACK;")
            return nil
        }

        bindString(statement, 1, capture.url.absoluteString)
        bindString(statement, 2, capture.title.trimmingCharacters(in: .whitespacesAndNewlines))
        bindString(statement, 3, timestamp)
        bindString(statement, 4, domHash)
        bindString(statement, 5, screenshotHash)
        bindString(statement, 6, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step insert visit")
            exec("ROLLBACK;")
            return nil
        }

        let visitID = sqlite3_last_insert_rowid(db)
        let insertedNetworkIDs = insertNetworkEvents(capture.networkEvents, visitID: visitID)
        if let firstID = insertedNetworkIDs.first {
            updateNetworkLogID(firstID, forVisitID: visitID)
        }

        exec("COMMIT;")
        didCommit = true
        enforceSizeLimit()
        return PageArchiveVisit(
            id: visitID,
            url: capture.url.absoluteString,
            title: capture.title,
            timestamp: capture.timestamp,
            domBlobHash: domHash,
            screenshotBlobHash: screenshotHash,
            networkLogID: insertedNetworkIDs.first,
            networkLogCount: insertedNetworkIDs.count
        )
    }

    @discardableResult
    func record(networkEvents events: [PageArchiveNetworkEvent], visitID: Int64) -> Bool {
        guard !events.isEmpty else { return true }
        let inserted = insertNetworkEvents(events, visitID: visitID)
        if let firstID = inserted.first {
            setNetworkLogIDIfMissing(firstID, forVisitID: visitID)
        }
        enforceSizeLimit()
        return !inserted.isEmpty
    }

    func query(url: String? = nil, sinceTs: Date? = nil, limit: Int = 20) -> [PageArchiveVisit] {
        guard let db else { return [] }

        var sql = """
        SELECT v.id, v.url, v.title, v.ts, v.dom_blob_hash, v.screenshot_blob_hash,
               v.network_log_id,
               (SELECT COUNT(*) FROM network_log n WHERE n.visit_id = v.id) AS network_count
        FROM visits v
        """
        var clauses: [String] = []
        var binds: [SQLValue] = []
        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clauses.append("v.url LIKE ? ESCAPE '\\'")
            binds.append(.string("%\(escapeLike(url.trimmingCharacters(in: .whitespacesAndNewlines)))%"))
        }
        if let sinceTs {
            clauses.append("v.ts >= ?")
            binds.append(.string(Self.iso8601Formatter.string(from: sinceTs)))
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY v.ts DESC LIMIT ?;"
        binds.append(.int(Int64(max(0, limit))))

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare query")
            return []
        }
        bindValues(binds, to: statement)
        return readVisits(from: statement)
    }

    func get(visitID: Int64) -> PageArchiveVisitDetails? {
        guard let db else { return nil }
        let sql = """
        SELECT v.id, v.url, v.title, v.ts, v.dom_blob_hash, v.screenshot_blob_hash,
               v.network_log_id,
               (SELECT COUNT(*) FROM network_log n WHERE n.visit_id = v.id) AS network_count
        FROM visits v
        WHERE v.id = ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare get visit")
            return nil
        }
        sqlite3_bind_int64(statement, 1, visitID)
        guard let visit = readVisits(from: statement).first else { return nil }

        touchVisit(visit)
        guard let domData = get(blobHash: visit.domBlobHash),
              let domHTML = String(data: domData, encoding: .utf8) else {
            return nil
        }
        _ = touchBlob(hash: visit.screenshotBlobHash, now: Date())

        return PageArchiveVisitDetails(
            visit: visit,
            domHTML: domHTML,
            screenshotURL: blobURL(for: visit.screenshotBlobHash),
            networkLog: networkLog(forVisitID: visitID)
        )
    }

    func get(blobHash: String) -> Data? {
        guard Self.isValidHash(blobHash) else { return nil }
        _ = touchBlob(hash: blobHash, now: Date())
        return try? Data(contentsOf: blobURL(for: blobHash))
    }

    @discardableResult
    func prune(olderThan cutoff: Date) -> Int {
        guard let db else { return 0 }
        let sql = "DELETE FROM visits WHERE ts < ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare prune older")
            return 0
        }
        bindString(statement, 1, Self.iso8601Formatter.string(from: cutoff))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step prune older")
            return 0
        }
        let removed = Int(sqlite3_changes(db))
        removeUnreferencedBlobs()
        return removed
    }

    @discardableResult
    func storeBlob(_ data: Data, now: Date = Date()) -> String? {
        guard let db else { return nil }
        let hash = Self.sha256Hex(data)
        let url = blobURL(for: hash)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: [.atomic])
            }
        } catch {
            return nil
        }

        let sql = """
        INSERT INTO blobs (hash, size_bytes, last_accessed_ts)
        VALUES (?, ?, ?)
        ON CONFLICT(hash) DO UPDATE SET last_accessed_ts = excluded.last_accessed_ts;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare upsert blob")
            return nil
        }
        bindString(statement, 1, hash)
        sqlite3_bind_int64(statement, 2, Int64(data.count))
        bindString(statement, 3, Self.iso8601Formatter.string(from: now))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step upsert blob")
            return nil
        }
        return hash
    }

    func blobURL(for hash: String) -> URL {
        let first = String(hash.prefix(2))
        let secondStart = hash.index(hash.startIndex, offsetBy: min(2, hash.count))
        let secondEnd = hash.index(hash.startIndex, offsetBy: min(4, hash.count))
        let second = String(hash[secondStart..<secondEnd])
        return rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
            .appendingPathComponent(first, isDirectory: true)
            .appendingPathComponent(second, isDirectory: true)
            .appendingPathComponent(hash)
    }

    func blobFileCount() -> Int {
        let blobRoot = rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: blobRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    func shouldArchive(url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: PreferenceKey.pageArchiveEnabled) as? Bool ?? true else {
            return false
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return false
        }
        return !Self.deniedDomains(defaults: defaults).contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    func enforceSizeLimit(maxBytes explicitMaxBytes: Int64? = nil) {
        let cap = explicitMaxBytes ?? maxArchiveSizeBytes ?? Self.configuredMaxArchiveSizeBytes()
        guard cap > 0 else { return }

        removeUnreferencedBlobs()
        var guardCount = 0
        while currentBlobStorageBytes() > cap && guardCount < 10_000 {
            guardCount += 1
            if deleteLeastRecentlyAccessedVisit() {
                removeUnreferencedBlobs()
            } else if !deleteLeastRecentlyAccessedBlob() {
                break
            }
        }
    }

    nonisolated static func parseTimestamp(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - Schema

    private func open() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "PageArchive", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open archive index at \(databaseURL.path)"
            ])
        }
        db = handle
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)

        let schema = """
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            ts TEXT NOT NULL,
            dom_blob_hash TEXT NOT NULL,
            screenshot_blob_hash TEXT NOT NULL,
            network_log_id INTEGER,
            last_accessed_ts TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS network_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            visit_id INTEGER NOT NULL REFERENCES visits(id) ON DELETE CASCADE,
            ts TEXT NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            status INTEGER,
            type TEXT NOT NULL DEFAULT '',
            request_headers TEXT NOT NULL DEFAULT '{}',
            response_headers TEXT NOT NULL DEFAULT '{}',
            body_blob_hash TEXT,
            duration_ms REAL
        );
        CREATE TABLE IF NOT EXISTS blobs (
            hash TEXT PRIMARY KEY,
            size_bytes INTEGER NOT NULL,
            last_accessed_ts TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visits_ts ON visits (ts DESC);
        CREATE INDEX IF NOT EXISTS visits_url ON visits (url);
        CREATE INDEX IF NOT EXISTS visits_last_accessed ON visits (last_accessed_ts ASC);
        CREATE INDEX IF NOT EXISTS network_log_visit_id ON network_log (visit_id);
        CREATE INDEX IF NOT EXISTS blobs_last_accessed ON blobs (last_accessed_ts ASC);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
    }

    // MARK: - Network rows

    @discardableResult
    private func insertNetworkEvents(_ events: [PageArchiveNetworkEvent], visitID: Int64) -> [Int64] {
        guard let db, !events.isEmpty else { return [] }
        let sql = """
        INSERT INTO network_log
            (visit_id, ts, method, url, status, type, request_headers, response_headers,
             body_blob_hash, duration_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insertedIDs: [Int64] = []

        for event in events where !event.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bodyHash = storeBodyBlob(for: event)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                logSQLiteError(context: "prepare insert network")
                continue
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, visitID)
            bindString(statement, 2, Self.iso8601Formatter.string(from: event.timestamp))
            bindString(statement, 3, event.method.uppercased())
            bindString(statement, 4, event.url)
            if let status = event.status {
                sqlite3_bind_int(statement, 5, Int32(status))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            bindString(statement, 6, event.type)
            bindString(statement, 7, Self.jsonString(event.requestHeaders))
            bindString(statement, 8, Self.jsonString(event.responseHeaders))
            bindOptionalString(statement, 9, bodyHash)
            if let durationMS = event.durationMS {
                sqlite3_bind_double(statement, 10, durationMS)
            } else {
                sqlite3_bind_null(statement, 10)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                logSQLiteError(context: "step insert network")
                continue
            }
            insertedIDs.append(sqlite3_last_insert_rowid(db))
        }

        return insertedIDs
    }

    private func storeBodyBlob(for event: PageArchiveNetworkEvent) -> String? {
        guard event.requestBody != nil || event.responseBody != nil else { return nil }
        let envelope = NetworkBodyEnvelope(request: event.requestBody, response: event.responseBody)
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return storeBlob(data, now: event.timestamp)
    }

    private func networkLog(forVisitID visitID: Int64) -> [PageArchiveNetworkLogEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT id, visit_id, ts, method, url, status, type, request_headers,
               response_headers, body_blob_hash, duration_ms
        FROM network_log
        WHERE visit_id = ?
        ORDER BY ts ASC, id ASC;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare network log")
            return []
        }
        sqlite3_bind_int64(statement, 1, visitID)

        var rows: [PageArchiveNetworkLogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bodyHash = readOptionalString(statement, 9)
            let body: String?
            if let bodyHash, let data = get(blobHash: bodyHash) {
                body = String(data: data, encoding: .utf8)
            } else {
                body = nil
            }

            let status: Int?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                status = nil
            } else {
                status = Int(sqlite3_column_int(statement, 5))
            }

            let durationMS: Double?
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                durationMS = nil
            } else {
                durationMS = sqlite3_column_double(statement, 10)
            }

            rows.append(PageArchiveNetworkLogEntry(
                id: sqlite3_column_int64(statement, 0),
                visitID: sqlite3_column_int64(statement, 1),
                timestamp: Self.iso8601Formatter.date(from: readString(statement, 2)) ?? Date(),
                method: readString(statement, 3),
                url: readString(statement, 4),
                status: status,
                type: readString(statement, 6),
                requestHeaders: Self.jsonDictionary(readString(statement, 7)),
                responseHeaders: Self.jsonDictionary(readString(statement, 8)),
                bodyBlobHash: bodyHash,
                body: body,
                durationMS: durationMS
            ))
        }
        return rows
    }

    private func updateNetworkLogID(_ networkLogID: Int64, forVisitID visitID: Int64) {
        guard let db else { return }
        let sql = "UPDATE visits SET network_log_id = ? WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, networkLogID)
        sqlite3_bind_int64(statement, 2, visitID)
        sqlite3_step(statement)
    }

    private func setNetworkLogIDIfMissing(_ networkLogID: Int64, forVisitID visitID: Int64) {
        guard let db else { return }
        let sql = "UPDATE visits SET network_log_id = ? WHERE id = ? AND network_log_id IS NULL;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, networkLogID)
        sqlite3_bind_int64(statement, 2, visitID)
        sqlite3_step(statement)
    }

    // MARK: - Pruning

    private func currentBlobStorageBytes() -> Int64 {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(size_bytes), 0) FROM blobs;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func deleteLeastRecentlyAccessedVisit() -> Bool {
        guard let db else { return false }
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        let selectSQL = "SELECT id FROM visits ORDER BY last_accessed_ts ASC, ts ASC LIMIT 1;"
        guard sqlite3_prepare_v2(db, selectSQL, -1, &select, nil) == SQLITE_OK,
              sqlite3_step(select) == SQLITE_ROW else {
            return false
        }
        let id = sqlite3_column_int64(select, 0)

        var delete: OpaquePointer?
        defer { sqlite3_finalize(delete) }
        guard sqlite3_prepare_v2(db, "DELETE FROM visits WHERE id = ?;", -1, &delete, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_int64(delete, 1, id)
        return sqlite3_step(delete) == SQLITE_DONE && sqlite3_changes(db) > 0
    }

    private func deleteLeastRecentlyAccessedBlob() -> Bool {
        guard let db else { return false }
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        let selectSQL = "SELECT hash FROM blobs ORDER BY last_accessed_ts ASC LIMIT 1;"
        guard sqlite3_prepare_v2(db, selectSQL, -1, &select, nil) == SQLITE_OK,
              sqlite3_step(select) == SQLITE_ROW else {
            return false
        }
        return deleteBlob(hash: readString(select, 0))
    }

    private func removeUnreferencedBlobs() {
        guard let db else { return }
        let sql = """
        SELECT b.hash
        FROM blobs b
        WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.dom_blob_hash = b.hash)
          AND NOT EXISTS (SELECT 1 FROM visits v WHERE v.screenshot_blob_hash = b.hash)
          AND NOT EXISTS (SELECT 1 FROM network_log n WHERE n.body_blob_hash = b.hash);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }

        var hashes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            hashes.append(readString(statement, 0))
        }
        for hash in hashes {
            _ = deleteBlob(hash: hash)
        }
    }

    @discardableResult
    private func deleteBlob(hash: String) -> Bool {
        guard let db else { return false }
        try? FileManager.default.removeItem(at: blobURL(for: hash))

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM blobs WHERE hash = ?;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        bindString(statement, 1, hash)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Access tracking

    private func touchVisit(_ visit: PageArchiveVisit) {
        let now = Date()
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE visits SET last_accessed_ts = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
            return
        }
        bindString(statement, 1, Self.iso8601Formatter.string(from: now))
        sqlite3_bind_int64(statement, 2, visit.id)
        sqlite3_step(statement)
        _ = touchBlob(hash: visit.domBlobHash, now: now)
        _ = touchBlob(hash: visit.screenshotBlobHash, now: now)
    }

    @discardableResult
    private func touchBlob(hash: String, now: Date) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "UPDATE blobs SET last_accessed_ts = ? WHERE hash = ?;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        bindString(statement, 1, Self.iso8601Formatter.string(from: now))
        bindString(statement, 2, hash)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Read helpers

    private func readVisits(from statement: OpaquePointer?) -> [PageArchiveVisit] {
        var results: [PageArchiveVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let networkLogID: Int64?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                networkLogID = nil
            } else {
                networkLogID = sqlite3_column_int64(statement, 6)
            }

            results.append(PageArchiveVisit(
                id: sqlite3_column_int64(statement, 0),
                url: readString(statement, 1),
                title: readString(statement, 2),
                timestamp: Self.iso8601Formatter.date(from: readString(statement, 3)) ?? Date(),
                domBlobHash: readString(statement, 4),
                screenshotBlobHash: readString(statement, 5),
                networkLogID: networkLogID,
                networkLogCount: Int(sqlite3_column_int(statement, 7))
            ))
        }
        return results
    }

    // MARK: - Bind helpers

    private enum SQLValue {
        case string(String)
        case int(Int64)
    }

    private func bindValues(_ values: [SQLValue], to statement: OpaquePointer?) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .string(let string):
                bindString(statement, index, string)
            case .int(let int):
                sqlite3_bind_int64(statement, index, int)
            }
        }
    }

    private func bindString(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bindOptionalString(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindString(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func readString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func readOptionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func logSQLiteError(context: String) {
        #if DEBUG
        if let db, let messagePointer = sqlite3_errmsg(db) {
            print("PageArchive [\(context)]:", String(cString: messagePointer))
        }
        #endif
    }

    // MARK: - Static helpers

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(String(character))
        }
    }

    private static func jsonString(_ dictionary: [String: String]) -> String {
        guard !dictionary.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func jsonDictionary(_ string: String) -> [String: String] {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            result[key] = String(describing: value)
        }
        return result
    }

    private static func configuredMaxArchiveSizeBytes(defaults: UserDefaults = .standard) -> Int64 {
        if let number = defaults.object(forKey: PreferenceKey.pageArchiveMaxBytes) as? NSNumber,
           number.int64Value > 0 {
            return number.int64Value
        }
        return defaultMaxArchiveSizeBytes
    }

    private static func deniedDomains(defaults: UserDefaults) -> [String] {
        let configured = defaults.string(forKey: PreferenceKey.pageArchiveDenylist) ?? ""
        let extra = configured
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return (defaultDenylist + extra).removingDuplicates()
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct NetworkBodyEnvelope: Codable, Equatable {
    var request: String?
    var response: String?
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
