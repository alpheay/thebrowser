import Foundation
import SQLite3

/// Local-only SQLite log of every web page the user has visited. Mirrors
/// ``CitedClipboardStore``'s threading model — main-actor isolated, single
/// system-libsqlite3 handle, change broadcasts via NotificationCenter.
///
/// Schema is intentionally wider than today's UI needs: `summary` and
/// `embedding` are reserved for the planned Personal Knowledge Graph
/// feature. They're nullable so visit recording stays cheap.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
    }()

    /// Notification posted on the main thread whenever the store changes
    /// (insert, delete, or clear). The History modal observes this to refresh.
    static let didChangeNotification = Notification.Name("HistoryStore.didChange")

    /// Two visits to the same URL within this window collapse into a single
    /// row with an incremented ``HistoryEntry/visitCount``. Mirrors Chromium's
    /// per-URL "visit segment" heuristic — long enough to absorb redirect
    /// chains and pagination, short enough that genuinely separate visits to
    /// the same page each get their own timestamp.
    static let dedupeWindow: TimeInterval = 60

    private let databaseURL: URL
    /// `nonisolated(unsafe)` for the deinit close, same justification as in
    /// ``CitedClipboardStore``: this type is MainActor-isolated and the
    /// handle is never touched from another thread.
    nonisolated(unsafe) private var db: OpaquePointer?

    init(databaseURL: URL = HistoryStore.rootURL.appendingPathComponent("history.sqlite")) {
        self.databaseURL = databaseURL
        try? open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Records a visit to `url`. The schema enforces UNIQUE(url) so only one
    /// row per URL ever exists; revisits bump `visit_count` and refresh
    /// `last_visited_at` via INSERT … ON CONFLICT. The ``dedupeWindow`` is
    /// enforced by callers (``BrowserTab/recordVisitToHistory``) so that
    /// WebKit's repeated `didFinish` notifications for one page load don't
    /// inflate the count — by the time the store sees a duplicate URL, the
    /// caller has already decided it's a real revisit.
    @discardableResult
    func recordVisit(
        url: URL,
        title: String?,
        tabID: String? = nil,
        sessionID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard Self.shouldRecord(url: url) else { return false }
        return insertOrBump(
            url: url.absoluteString,
            title: title ?? "",
            kind: .visit,
            tabID: tabID,
            sessionID: sessionID,
            now: now
        )
    }

    /// Records an in-app search the user typed into the URL bar. Searches
    /// never trigger an outbound navigation in TheBrowser — they render a
    /// local `SearchResultsView` — so the URL stored here is synthesized
    /// from the configured engine and used purely as a stable dedup key
    /// (same query + same engine → bumps `visit_count`, doesn't add a row).
    /// The raw query is kept in `title` so the modal can display it and
    /// re-run it via ``BrowserTab/navigate(to:)``.
    @discardableResult
    func recordSearch(
        query: String,
        engine: String,
        tabID: String? = nil,
        sessionID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = Self.searchURLKey(query: trimmed, engine: engine)
        return insertOrBump(
            url: key,
            title: trimmed,
            kind: .search,
            tabID: tabID,
            sessionID: sessionID,
            now: now
        )
    }

    /// Synthesizes a stable storage key for a search row. Lowercases the
    /// query so "swift" and "Swift" share a row, and includes the engine so
    /// the same query against two different engines stays distinct in case
    /// the user changes their default later.
    static func searchURLKey(query: String, engine: String) -> String {
        let normalizedQuery = query.lowercased()
        let encoded = normalizedQuery
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? normalizedQuery
        return "thebrowser-search://\(engine.lowercased())?q=\(encoded)"
    }

    private func insertOrBump(
        url: String,
        title: String,
        kind: HistoryEntryKind,
        tabID: String?,
        sessionID: String?,
        now: Date
    ) -> Bool {
        guard let db else { return false }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = Self.iso8601Formatter.string(from: now)

        let sql = """
        INSERT INTO history (
            url, title, favicon_path, visited_at, visit_count,
            last_visited_at, tab_id, session_id, summary, embedding, kind
        )
        VALUES (?, ?, NULL, ?, 1, ?, ?, ?, NULL, NULL, ?)
        ON CONFLICT(url) DO UPDATE SET
            visit_count = history.visit_count + 1,
            last_visited_at = excluded.last_visited_at,
            title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE history.title END,
            tab_id = COALESCE(excluded.tab_id, history.tab_id),
            session_id = COALESCE(excluded.session_id, history.session_id);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare insert")
            return false
        }

        bindString(statement, 1, url)
        bindString(statement, 2, cleanTitle)
        bindString(statement, 3, timestamp)
        bindString(statement, 4, timestamp)
        bindOptionalString(statement, 5, tabID)
        bindOptionalString(statement, 6, sessionID)
        bindString(statement, 7, kind.rawValue)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step insert")
            return false
        }

        broadcastChange()
        return true
    }

    /// Updates the title on the existing row for `url` without bumping
    /// `visit_count` or `last_visited_at`. Used by the title-KVO callback
    /// in ``BrowserTab`` so the row written on `didFinish` (often before
    /// the page title arrives) gets backfilled with the real title.
    @discardableResult
    func updateTitle(forURL url: URL, title: String) -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, let db else { return false }
        let sql = "UPDATE history SET title = ? WHERE url = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare update title")
            return false
        }
        bindString(statement, 1, cleanTitle)
        bindString(statement, 2, url.absoluteString)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step update title")
            return false
        }
        if sqlite3_changes(db) > 0 {
            broadcastChange()
            return true
        }
        return false
    }

    /// Backfill entrypoint for the migration importer. Each entry becomes a
    /// single history row; if the URL already exists in the store its
    /// `visit_count` is added and `last_visited_at` is bumped to the more
    /// recent of the two. Used from the one-time backfill on first launch
    /// and any time Migration completes — see ``importMigratedEntries``.
    @discardableResult
    func upsertImportedEntry(
        url: URL,
        title: String,
        visitCount: Int,
        lastVisitedAt: Date?
    ) -> Bool {
        guard Self.shouldRecord(url: url) else { return false }
        guard let db else { return false }

        let normalized = url.absoluteString
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.iso8601Formatter.string(from: lastVisitedAt ?? Date())
        let count = max(1, visitCount)

        let sql = """
        INSERT INTO history (
            url, title, favicon_path, visited_at, visit_count,
            last_visited_at, tab_id, session_id, summary, embedding, kind
        )
        VALUES (?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, NULL, 'visit')
        ON CONFLICT(url) DO UPDATE SET
            title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE history.title END,
            visit_count = history.visit_count + excluded.visit_count,
            last_visited_at = CASE
                WHEN excluded.last_visited_at > history.last_visited_at THEN excluded.last_visited_at
                ELSE history.last_visited_at
            END;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare upsert")
            return false
        }

        bindString(statement, 1, normalized)
        bindString(statement, 2, cleanTitle)
        bindString(statement, 3, stamp)
        sqlite3_bind_int(statement, 4, Int32(count))
        bindString(statement, 5, stamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step upsert")
            return false
        }

        return true
    }

    /// Returns visits in the supplied window, newest first. `range` is
    /// inclusive on both ends; pass `nil` for an open bound. The History
    /// modal uses this with no range to render the full timeline.
    func listHistory(
        range: ClosedRange<Date>? = nil,
        limit: Int = 1_000,
        offset: Int = 0
    ) -> [HistoryEntry] {
        guard let db else { return [] }

        var sql = """
        SELECT id, url, title, favicon_path, visited_at, visit_count,
               last_visited_at, tab_id, session_id, summary, kind
        FROM history
        """
        if range != nil {
            sql += " WHERE last_visited_at BETWEEN ? AND ?"
        }
        sql += " ORDER BY last_visited_at DESC LIMIT ? OFFSET ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare list")
            return []
        }

        var index: Int32 = 1
        if let range {
            bindString(statement, index, Self.iso8601Formatter.string(from: range.lowerBound))
            index += 1
            bindString(statement, index, Self.iso8601Formatter.string(from: range.upperBound))
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(max(0, limit)))
        index += 1
        sqlite3_bind_int(statement, index, Int32(max(0, offset)))

        return readEntries(from: statement)
    }

    /// Case-insensitive substring match across `title` and `url`. Newest
    /// first. Trims whitespace from `query`; returns an empty list when the
    /// trimmed query is empty (callers should fall back to ``listHistory``).
    func searchHistory(query: String, limit: Int = 500) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db else { return [] }

        let sql = """
        SELECT id, url, title, favicon_path, visited_at, visit_count,
               last_visited_at, tab_id, session_id, summary, kind
        FROM history
        WHERE url LIKE ? COLLATE NOCASE OR title LIKE ? COLLATE NOCASE
        ORDER BY last_visited_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare search")
            return []
        }

        let pattern = "%\(escapeLike(trimmed))%"
        bindString(statement, 1, pattern)
        bindString(statement, 2, pattern)
        sqlite3_bind_int(statement, 3, Int32(max(0, limit)))

        return readEntries(from: statement)
    }

    /// Removes a single visit row by primary key. Used from the modal's
    /// right-click "Delete" affordance.
    @discardableResult
    func deleteEntry(id: Int64) -> Bool {
        guard let db else { return false }
        let sql = "DELETE FROM history WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare delete")
            return false
        }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step delete")
            return false
        }
        broadcastChange()
        return true
    }

    /// Removes every visit to `host`, matched against the URL's host
    /// component (case-insensitive). Used from the modal's "Forget all
    /// visits to this site" right-click option.
    @discardableResult
    func deleteEntries(host: String) -> Bool {
        guard let db, !host.isEmpty else { return false }
        // No native URL parsing in SQLite — match the host as a substring
        // between the scheme separator and the next slash. Belt-and-braces:
        // also trim a leading "www." so "Forget google.com" wipes
        // www.google.com too.
        let normalizedHost = host.lowercased().trimmingPrefix("www.")
        let entries = listHistory(limit: 10_000)
        let ids = entries.compactMap { entry -> Int64? in
            guard let entryHost = entry.url.host(percentEncoded: false)?.lowercased() else {
                return nil
            }
            let trimmed = entryHost.hasPrefix("www.") ? String(entryHost.dropFirst(4)) : entryHost
            return trimmed == normalizedHost ? entry.id : nil
        }
        guard !ids.isEmpty else { return false }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "DELETE FROM history WHERE id IN (\(placeholders));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare delete host")
            return false
        }
        for (offset, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), id)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step delete host")
            return false
        }
        broadcastChange()
        return true
    }

    /// Removes every visit whose `last_visited_at` falls in `range`.
    /// Inclusive on both ends, matching ``listHistory``.
    @discardableResult
    func deleteHistory(in range: ClosedRange<Date>) -> Bool {
        guard let db else { return false }
        let sql = "DELETE FROM history WHERE last_visited_at BETWEEN ? AND ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare delete range")
            return false
        }
        bindString(statement, 1, Self.iso8601Formatter.string(from: range.lowerBound))
        bindString(statement, 2, Self.iso8601Formatter.string(from: range.upperBound))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step delete range")
            return false
        }
        broadcastChange()
        return true
    }

    func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM history;", nil, nil, nil)
        broadcastChange()
    }

    /// Total visit-row count. Used by Settings and as an empty-state hint.
    func count() -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history;", -1, &statement, nil) == SQLITE_OK else {
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
            throw NSError(domain: "HistoryStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open history.sqlite at \(databaseURL.path)"
            ])
        }
        self.db = handle

        // `url` is unique so the migration upsert can collapse duplicates.
        // `summary` and `embedding` are forward-looking columns for the
        // planned Personal Knowledge Graph — kept nullable so today's writer
        // path doesn't have to know about them.
        let schema = """
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            favicon_path TEXT,
            visited_at TEXT NOT NULL,
            visit_count INTEGER NOT NULL DEFAULT 1,
            last_visited_at TEXT NOT NULL,
            tab_id TEXT,
            session_id TEXT,
            summary TEXT,
            embedding BLOB,
            kind TEXT NOT NULL DEFAULT 'visit'
        );
        CREATE INDEX IF NOT EXISTS history_last_visited ON history (last_visited_at DESC);
        CREATE INDEX IF NOT EXISTS history_url ON history (url);
        CREATE INDEX IF NOT EXISTS history_kind ON history (kind);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)

        // Migrate existing databases that predate the `kind` column.
        // `ALTER TABLE` is idempotent only if the column is missing — we
        // probe `PRAGMA table_info` rather than swallowing the error.
        if !columnExists("kind", on: "history") {
            sqlite3_exec(
                handle,
                "ALTER TABLE history ADD COLUMN kind TEXT NOT NULL DEFAULT 'visit';",
                nil, nil, nil
            )
            sqlite3_exec(
                handle,
                "CREATE INDEX IF NOT EXISTS history_kind ON history (kind);",
                nil, nil, nil
            )
        }
    }

    private func columnExists(_ column: String, on table: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            // Column 1 of `PRAGMA table_info` is the column name.
            if readString(statement, 1) == column { return true }
        }
        return false
    }

    private func readEntries(from statement: OpaquePointer?) -> [HistoryEntry] {
        var results: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let urlString = readString(statement, 1)
            guard let url = URL(string: urlString) else { continue }
            let title = readString(statement, 2)
            let favicon = readOptionalString(statement, 3)
            let visitedAt = Self.iso8601Formatter.date(from: readString(statement, 4)) ?? Date()
            let visitCount = Int(sqlite3_column_int(statement, 5))
            let lastVisitedAt = Self.iso8601Formatter.date(from: readString(statement, 6)) ?? visitedAt
            let tabID = readOptionalString(statement, 7)
            let sessionID = readOptionalString(statement, 8)
            let summary = readOptionalString(statement, 9)
            let kind = HistoryEntryKind(rawValue: readString(statement, 10)) ?? .visit
            results.append(HistoryEntry(
                id: id,
                url: url,
                title: title,
                faviconPath: favicon,
                visitedAt: visitedAt,
                visitCount: visitCount,
                lastVisitedAt: lastVisitedAt,
                tabID: tabID,
                sessionID: sessionID,
                summary: summary,
                kind: kind
            ))
        }
        return results
    }

    // MARK: - Helpers

    /// Filters out URLs that should never enter the history log: data:,
    /// about:blank, the file:// artifact path, and anything without a
    /// recognizable host. Mirrors what other browsers exclude from history.
    static func shouldRecord(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return url.host(percentEncoded: false)?.isEmpty == false
        default:
            return false
        }
    }

    private func broadcastChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
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

    /// Escapes the `LIKE`-special characters (`%`, `_`, `\`) so a literal
    /// underscore in a URL doesn't match every other character.
    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func logSQLiteError(context: String) {
        #if DEBUG
        if let db, let messagePointer = sqlite3_errmsg(db) {
            print("HistoryStore [\(context)]:", String(cString: messagePointer))
        }
        #endif
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Domain types

/// Type of history row. `visit` is a page the user navigated to; `search`
/// is a query they typed into the URL bar that surfaced TheBrowser's local
/// `SearchResultsView`. Stored as a column so the modal can filter, group,
/// and style the two cases differently.
enum HistoryEntryKind: String, CaseIterable, Hashable, Sendable {
    case visit
    case search
}

struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let url: URL
    let title: String
    let faviconPath: String?
    let visitedAt: Date
    let visitCount: Int
    let lastVisitedAt: Date
    let tabID: String?
    let sessionID: String?
    let summary: String?
    let kind: HistoryEntryKind

    /// Title to render — falls back to the URL host (or the full URL string
    /// when there's no host) so a row never appears blank in the modal.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url.host(percentEncoded: false), !host.isEmpty { return host }
        return url.absoluteString
    }

    var host: String? {
        url.host(percentEncoded: false)
    }

    /// True for searches the user typed into the URL bar. Drives the
    /// alternate row presentation in the modal (search-glyph chip,
    /// "Search · Engine" subtitle, click re-runs the query).
    var isSearch: Bool { kind == .search }

    /// Engine name pulled from the synthetic search URL — only meaningful
    /// when ``isSearch`` is true. Falls back to "Search" if the URL doesn't
    /// match the synthesizer's format.
    var searchEngineLabel: String? {
        guard isSearch, url.scheme == "thebrowser-search" else { return nil }
        return url.host?.capitalized
    }
}

// MARK: - Clear range

/// Choices offered by the Settings → History "Clear history…" menu. The
/// raw values are stored only to drive the menu order.
enum HistoryClearRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour
    case lastDay
    case lastWeek
    case allTime

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .lastHour: "Last hour"
        case .lastDay: "Last 24 hours"
        case .lastWeek: "Last 7 days"
        case .allTime: "All time"
        }
    }

    var alertNoun: String {
        switch self {
        case .lastHour: "last hour"
        case .lastDay: "last 24 hours"
        case .lastWeek: "last 7 days"
        case .allTime: "all browsing history"
        }
    }

    var alertBody: String {
        switch self {
        case .lastHour:
            return "Removes every visit recorded in the last hour. Cookies and cached files are not affected."
        case .lastDay:
            return "Removes every visit recorded in the last 24 hours. Cookies and cached files are not affected."
        case .lastWeek:
            return "Removes every visit recorded in the last 7 days. Cookies and cached files are not affected."
        case .allTime:
            return "Permanently deletes every entry in ~/.thebrowser/history.sqlite. Cookies and cached files are not affected."
        }
    }
}

// MARK: - Migration backfill

extension HistoryStore {
    /// Imports every row from ``MigrationImportStore`` into the SQLite log,
    /// upserting on URL. Cheap and idempotent — safe to call from both the
    /// one-time backfill and the post-migration hook.
    @discardableResult
    func importMigratedEntries(_ entries: [ImportedHistoryEntry]) -> Int {
        guard !entries.isEmpty else { return 0 }
        var imported = 0
        for entry in entries {
            guard let url = URL(string: entry.url) else { continue }
            if upsertImportedEntry(
                url: url,
                title: entry.title,
                visitCount: max(1, entry.visitCount),
                lastVisitedAt: entry.lastVisitedAt
            ) {
                imported += 1
            }
        }
        if imported > 0 {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return imported
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
