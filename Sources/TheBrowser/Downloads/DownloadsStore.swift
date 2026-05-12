import Foundation
import SQLite3

/// Local SQLite log of every WKDownload the user has started. Mirrors
/// ``CitedClipboardStore`` — main-actor isolated, libsqlite3 from the system
/// SDK, no third-party dependency. Tracks history across launches so the
/// popover's "Recent" section persists.
@MainActor
final class DownloadsStore {
    static let shared = DownloadsStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
    }()

    /// Maximum number of rows retained on disk. The newest entries win.
    static let maxEntries = 500

    /// Posted on the main thread after any insert, update, or delete. The
    /// ``DownloadController`` already publishes its own live list, but the
    /// popover also listens here so external mutations (clear-on-quit, a
    /// future "Open downloads.sqlite" debug path) refresh the UI.
    static let didChangeNotification = Notification.Name("DownloadsStore.didChange")

    private let databaseURL: URL
    nonisolated(unsafe) private var db: OpaquePointer?

    init(databaseURL: URL = DownloadsStore.rootURL.appendingPathComponent("downloads.sqlite")) {
        self.databaseURL = databaseURL
        try? open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Persists the initial row for a freshly-started download. The caller
    /// (``DownloadController``) provides the UUID so the in-memory and
    /// on-disk views share an identifier without a round-trip.
    @discardableResult
    func createDownload(_ record: DownloadRecord) -> Bool {
        guard let db else { return false }

        let sql = """
        INSERT OR REPLACE INTO downloads
            (id, url, filename, destination_path, mime_type, started_at,
             completed_at, bytes_received, bytes_total, state, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare createDownload")
            return false
        }

        bindString(statement, 1, record.id)
        bindString(statement, 2, record.url)
        bindString(statement, 3, record.filename)
        bindString(statement, 4, record.destinationPath)
        bindString(statement, 5, record.mimeType)
        bindString(statement, 6, Self.iso8601Formatter.string(from: record.startedAt))
        bindOptionalString(statement, 7, record.completedAt.map(Self.iso8601Formatter.string(from:)))
        sqlite3_bind_int64(statement, 8, record.bytesReceived)
        bindOptionalInt64(statement, 9, record.bytesTotal)
        bindString(statement, 10, record.state.rawValue)
        bindOptionalString(statement, 11, record.errorMessage)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step createDownload")
            return false
        }

        pruneToCap()
        broadcastChange()
        return true
    }

    @discardableResult
    func updateProgress(id: String, bytesReceived: Int64, bytesTotal: Int64?) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = """
        UPDATE downloads
        SET bytes_received = ?, bytes_total = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare updateProgress")
            return false
        }
        sqlite3_bind_int64(statement, 1, bytesReceived)
        bindOptionalInt64(statement, 2, bytesTotal)
        bindString(statement, 3, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step updateProgress")
            return false
        }
        // Progress updates fire many times per second — we don't broadcast
        // here. The popover reads live progress from ``DownloadController``
        // instead.
        return true
    }

    @discardableResult
    func updateState(id: String, state: DownloadRecord.State) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = "UPDATE downloads SET state = ? WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare updateState")
            return false
        }
        bindString(statement, 1, state.rawValue)
        bindString(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step updateState")
            return false
        }
        broadcastChange()
        return true
    }

    @discardableResult
    func updateDestination(id: String, destinationPath: String, filename: String) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = """
        UPDATE downloads
        SET destination_path = ?, filename = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare updateDestination")
            return false
        }
        bindString(statement, 1, destinationPath)
        bindString(statement, 2, filename)
        bindString(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step updateDestination")
            return false
        }
        broadcastChange()
        return true
    }

    @discardableResult
    func markCompleted(id: String, bytesReceived: Int64, completedAt: Date = Date()) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = """
        UPDATE downloads
        SET state = ?, completed_at = ?, bytes_received = ?, error_message = NULL
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare markCompleted")
            return false
        }
        bindString(statement, 1, DownloadRecord.State.completed.rawValue)
        bindString(statement, 2, Self.iso8601Formatter.string(from: completedAt))
        sqlite3_bind_int64(statement, 3, bytesReceived)
        bindString(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step markCompleted")
            return false
        }
        broadcastChange()
        return true
    }

    @discardableResult
    func markFailed(id: String, errorMessage: String?) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = """
        UPDATE downloads
        SET state = ?, error_message = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare markFailed")
            return false
        }
        bindString(statement, 1, DownloadRecord.State.failed.rawValue)
        bindOptionalString(statement, 2, errorMessage)
        bindString(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step markFailed")
            return false
        }
        broadcastChange()
        return true
    }

    /// Newest first.
    func listDownloads(limit: Int = DownloadsStore.maxEntries) -> [DownloadRecord] {
        guard let db else { return [] }

        let sql = """
        SELECT id, url, filename, destination_path, mime_type, started_at,
               completed_at, bytes_received, bytes_total, state, error_message
        FROM downloads
        ORDER BY started_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare listDownloads")
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))

        var results: [DownloadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(DownloadRecord(
                id: readString(statement, 0),
                url: readString(statement, 1),
                filename: readString(statement, 2),
                destinationPath: readString(statement, 3),
                mimeType: readString(statement, 4),
                startedAt: Self.iso8601Formatter.date(from: readString(statement, 5)) ?? Date(),
                completedAt: readOptionalString(statement, 6).flatMap(Self.iso8601Formatter.date(from:)),
                bytesReceived: sqlite3_column_int64(statement, 7),
                bytesTotal: readOptionalInt64(statement, 8),
                state: DownloadRecord.State(rawValue: readString(statement, 9)) ?? .failed,
                errorMessage: readOptionalString(statement, 10)
            ))
        }
        return results
    }

    @discardableResult
    func removeFromList(id: String) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = "DELETE FROM downloads WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare delete")
            return false
        }
        bindString(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step delete")
            return false
        }
        broadcastChange()
        return true
    }

    func clearCompleted() {
        guard let db else { return }
        let sql = "DELETE FROM downloads WHERE state IN ('completed', 'cancelled', 'failed');"
        sqlite3_exec(db, sql, nil, nil, nil)
        broadcastChange()
    }

    /// Migrates any rows that were "active" or "pending" at last quit into
    /// the failed state with a short reason. Called from
    /// ``DownloadController`` on init so the popover's "Active" section
    /// doesn't show ghost downloads from a previous run.
    func markInFlightAsInterrupted() {
        guard let db else { return }
        let sql = """
        UPDATE downloads
        SET state = 'failed', error_message = 'Interrupted at quit'
        WHERE state IN ('pending', 'active', 'paused');
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        broadcastChange()
    }

    // MARK: - Schema + lifecycle

    private func open() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "DownloadsStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open downloads.sqlite at \(databaseURL.path)"
            ])
        }
        self.db = handle

        let schema = """
        CREATE TABLE IF NOT EXISTS downloads (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL DEFAULT '',
            filename TEXT NOT NULL DEFAULT '',
            destination_path TEXT NOT NULL DEFAULT '',
            mime_type TEXT NOT NULL DEFAULT '',
            started_at TEXT NOT NULL,
            completed_at TEXT,
            bytes_received INTEGER NOT NULL DEFAULT 0,
            bytes_total INTEGER,
            state TEXT NOT NULL DEFAULT 'pending',
            error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS downloads_started_at ON downloads (started_at DESC);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
    }

    private func pruneToCap() {
        guard let db else { return }
        let sql = """
        DELETE FROM downloads WHERE id IN (
            SELECT id FROM downloads ORDER BY started_at DESC LIMIT -1 OFFSET ?
        );
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(statement, 1, Int32(Self.maxEntries))
        sqlite3_step(statement)
    }

    private func broadcastChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Bind / read helpers

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

    private func bindOptionalInt64(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
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
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    private func readOptionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func logSQLiteError(context: String) {
        #if DEBUG
        if let db, let messagePointer = sqlite3_errmsg(db) {
            print("DownloadsStore [\(context)]:", String(cString: messagePointer))
        }
        #endif
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
