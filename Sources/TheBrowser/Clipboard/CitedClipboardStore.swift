import Foundation
import SQLite3

/// Local-only SQLite log for captured clips, capped at the last 200 entries.
/// Backed by libsqlite3 from the system SDK so we don't take on a third-party
/// dependency. All access goes through the main actor — the store mirrors
/// ``ChatSessionStore``'s threading model.
@MainActor
final class CitedClipboardStore {
    static let shared = CitedClipboardStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
    }()

    /// Maximum number of clips kept on disk. The newest entries win — older
    /// ones get pruned after each insert.
    static let maxEntries = 200

    /// Notification posted on the main thread whenever the store changes
    /// (insert, delete, or clear). Settings + popover refresh from this.
    static let didChangeNotification = Notification.Name("CitedClipboardStore.didChange")

    private let databaseURL: URL
    /// `nonisolated(unsafe)` so the nonisolated deinit can close the
    /// handle. The store is MainActor-isolated; production usage hits the
    /// app-lifetime singleton (no deinit), tests construct isolated
    /// instances that do deinit. The handle is never touched from another
    /// thread, so the unchecked label is accurate in practice.
    nonisolated(unsafe) private var db: OpaquePointer?

    init(databaseURL: URL = CitedClipboardStore.rootURL.appendingPathComponent("clipboard.sqlite")) {
        self.databaseURL = databaseURL
        try? open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    @discardableResult
    func insert(_ clip: CitedClip) -> Bool {
        guard let db else { return false }

        let sql = """
        INSERT OR REPLACE INTO clips
            (id, text, source_url, source_title, page_domain, timestamp_iso,
             sentence_before, sentence_after, copied_from_tab_title)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare insert")
            return false
        }

        bindString(statement, 1, clip.id)
        bindString(statement, 2, clip.text)
        bindString(statement, 3, clip.sourceURL)
        bindString(statement, 4, clip.sourceTitle)
        bindString(statement, 5, clip.pageDomain)
        bindString(statement, 6, Self.iso8601Formatter.string(from: clip.timestamp))
        bindString(statement, 7, clip.sentenceBefore)
        bindString(statement, 8, clip.sentenceAfter)
        bindString(statement, 9, clip.copiedFromTabTitle)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step insert")
            return false
        }

        pruneToCap()
        broadcastChange()
        return true
    }

    /// Returns the newest clips first.
    func recentClips(limit: Int = CitedClipboardStore.maxEntries) -> [CitedClip] {
        guard let db else { return [] }

        let sql = """
        SELECT id, text, source_url, source_title, page_domain, timestamp_iso,
               sentence_before, sentence_after, copied_from_tab_title
        FROM clips
        ORDER BY timestamp_iso DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare select")
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))

        var results: [CitedClip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = readString(statement, 0)
            let text = readString(statement, 1)
            let sourceURL = readString(statement, 2)
            let sourceTitle = readString(statement, 3)
            let pageDomain = readString(statement, 4)
            let timestampISO = readString(statement, 5)
            let sentenceBefore = readString(statement, 6)
            let sentenceAfter = readString(statement, 7)
            let tabTitle = readString(statement, 8)
            let timestamp = Self.iso8601Formatter.date(from: timestampISO) ?? Date()
            results.append(CitedClip(
                id: id,
                text: text,
                sourceURL: sourceURL,
                sourceTitle: sourceTitle,
                pageDomain: pageDomain,
                timestamp: timestamp,
                sentenceBefore: sentenceBefore,
                sentenceAfter: sentenceAfter,
                copiedFromTabTitle: tabTitle
            ))
        }
        return results
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = "DELETE FROM clips WHERE id = ?;"
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

    func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM clips;", nil, nil, nil)
        broadcastChange()
    }

    /// Total clip count — used by the Settings empty state.
    func count() -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clips;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Schema + lifecycle

    private func open() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "CitedClipboardStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open clipboard.sqlite at \(databaseURL.path)"
            ])
        }
        self.db = handle

        let schema = """
        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            source_url TEXT NOT NULL DEFAULT '',
            source_title TEXT NOT NULL DEFAULT '',
            page_domain TEXT NOT NULL DEFAULT '',
            timestamp_iso TEXT NOT NULL,
            sentence_before TEXT NOT NULL DEFAULT '',
            sentence_after TEXT NOT NULL DEFAULT '',
            copied_from_tab_title TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS clips_ts ON clips (timestamp_iso DESC);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
    }

    /// Trims the oldest rows beyond ``maxEntries``. Cheap because the index
    /// on `timestamp_iso DESC` makes the inner SELECT a range scan.
    private func pruneToCap() {
        guard let db else { return }
        let sql = """
        DELETE FROM clips WHERE id IN (
            SELECT id FROM clips ORDER BY timestamp_iso DESC LIMIT -1 OFFSET ?
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
        // SQLITE_TRANSIENT (-1) tells SQLite to copy the bytes, since the
        // String's storage may not survive past this call.
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func readString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func logSQLiteError(context: String) {
        #if DEBUG
        if let db, let messagePointer = sqlite3_errmsg(db) {
            print("CitedClipboardStore [\(context)]:", String(cString: messagePointer))
        }
        #endif
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
