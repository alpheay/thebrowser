import Foundation
import SQLite3

/// Local-only SQLite store for the user's bookmarks. Schema mirrors the
/// `Bookmark` struct one-for-one, plus a nullable `embedding` BLOB column
/// reserved for the future semantic-search seam — readers/writers don't
/// touch it today.
///
/// Threading mirrors ``CitedClipboardStore``: all access is main-actor and
/// the connection handle is closed in a nonisolated deinit.
@MainActor
final class BookmarksStore {
    static let shared = BookmarksStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
    }()

    /// Notification posted on the main thread whenever the store changes
    /// (insert, delete, update, reorder, folder move). UI surfaces refresh
    /// from this.
    static let didChangeNotification = Notification.Name("BookmarksStore.didChange")

    private let databaseURL: URL
    nonisolated(unsafe) private var db: OpaquePointer?

    init(databaseURL: URL = BookmarksStore.rootURL.appendingPathComponent("bookmarks.sqlite")) {
        self.databaseURL = databaseURL
        try? open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Inserts a new bookmark. If a row already exists for the same URL it
    /// is left alone (returning false) so star-ing the same page twice
    /// doesn't clobber existing tags. Caller-supplied `id` is honored when
    /// non-empty; otherwise we mint a fresh UUID.
    @discardableResult
    func addBookmark(_ bookmark: Bookmark) -> Bool {
        guard let db, !bookmark.url.isEmpty else { return false }

        let sql = """
        INSERT OR IGNORE INTO bookmarks
            (id, url, title, favicon_path, folder, created_at_iso, tags_json, description, embedding)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare add")
            return false
        }

        let id = bookmark.id.isEmpty ? UUID().uuidString : bookmark.id
        bindString(statement, 1, id)
        bindString(statement, 2, bookmark.url)
        bindString(statement, 3, bookmark.title)
        bindString(statement, 4, bookmark.faviconPath)
        bindString(statement, 5, bookmark.folder)
        bindString(statement, 6, Self.iso8601Formatter.string(from: bookmark.createdAt))
        bindString(statement, 7, Self.encodeTags(bookmark.tags))
        bindString(statement, 8, bookmark.descriptionText)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step add")
            return false
        }

        guard sqlite3_changes(db) > 0 else { return false }

        broadcastChange()
        return true
    }

    @discardableResult
    func removeBookmark(id: String) -> Bool {
        guard let db, !id.isEmpty else { return false }
        let sql = "DELETE FROM bookmarks WHERE id = ?;"
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

    @discardableResult
    func removeBookmark(url: String) -> Bool {
        guard let db, !url.isEmpty else { return false }
        let sql = "DELETE FROM bookmarks WHERE url = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        bindString(statement, 1, url)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        broadcastChange()
        return true
    }

    /// Updates editable fields (title, folder, tags, description). The URL
    /// and `createdAt` are immutable once stored.
    @discardableResult
    func updateBookmark(
        id: String,
        title: String? = nil,
        folder: String? = nil,
        tags: [String]? = nil,
        descriptionText: String? = nil
    ) -> Bool {
        guard let db, !id.isEmpty else { return false }

        var setClauses: [String] = []
        var stringValues: [String] = []

        if let title { setClauses.append("title = ?"); stringValues.append(title) }
        if let folder { setClauses.append("folder = ?"); stringValues.append(folder) }
        if let tags { setClauses.append("tags_json = ?"); stringValues.append(Self.encodeTags(tags)) }
        if let descriptionText { setClauses.append("description = ?"); stringValues.append(descriptionText) }

        guard !setClauses.isEmpty else { return false }

        let sql = "UPDATE bookmarks SET \(setClauses.joined(separator: ", ")) WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare update")
            return false
        }

        var index: Int32 = 1
        for value in stringValues {
            bindString(statement, index, value)
            index += 1
        }
        bindString(statement, index, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSQLiteError(context: "step update")
            return false
        }
        broadcastChange()
        return true
    }

    @discardableResult
    func moveToFolder(id: String, folder: String) -> Bool {
        updateBookmark(id: id, folder: folder)
    }

    /// Returns every bookmark, newest first. Cheap — bookmarks count tops
    /// out in the low thousands even after a full Chrome import.
    func listBookmarks() -> [Bookmark] {
        guard let db else { return [] }

        let sql = """
        SELECT id, url, title, favicon_path, folder, created_at_iso, tags_json, description
        FROM bookmarks
        ORDER BY created_at_iso DESC;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare list")
            return []
        }

        var rows: [Bookmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(readBookmark(statement))
        }
        return rows
    }

    /// Subset: rows that have not yet been enriched by the AI tagger. Used
    /// by the migration backfill to enqueue work.
    func listUntaggedBookmarks() -> [Bookmark] {
        listBookmarks().filter { !$0.hasAITags }
    }

    /// Keyword search over title, URL, tags, and AI description with simple
    /// LIKE; tag filter chips ANDed in via the `tags` parameter.
    func searchBookmarks(query: String, tags: [String] = []) -> [Bookmark] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || !tags.isEmpty else {
            return listBookmarks()
        }

        // Tag matching uses substring lookups inside the JSON string.
        // The tag values are always lowercase and short — false positives
        // (e.g. tag "ai" matching the word "ai" elsewhere in JSON) aren't
        // really possible because the JSON quotes them: `"ai"`.
        var clauses: [String] = []
        var stringValues: [String] = []

        if !trimmedQuery.isEmpty {
            let like = "%\(trimmedQuery.lowercased())%"
            clauses.append("""
            (LOWER(title) LIKE ? OR LOWER(url) LIKE ? OR LOWER(tags_json) LIKE ? OR LOWER(description) LIKE ?)
            """)
            stringValues.append(contentsOf: [like, like, like, like])
        }

        for tag in tags {
            clauses.append("LOWER(tags_json) LIKE ?")
            stringValues.append("%\"\(tag.lowercased())\"%")
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
        SELECT id, url, title, favicon_path, folder, created_at_iso, tags_json, description
        FROM bookmarks
        \(whereClause)
        ORDER BY created_at_iso DESC;
        """

        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare search")
            return []
        }

        var index: Int32 = 1
        for value in stringValues {
            bindString(statement, index, value)
            index += 1
        }

        var rows: [Bookmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(readBookmark(statement))
        }
        return rows
    }

    /// True when the given URL is already saved. Powers the star icon's
    /// "lit when bookmarked" state in the address bar.
    func isBookmarked(url: String) -> Bool {
        guard let db, !url.isEmpty else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM bookmarks WHERE url = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        bindString(statement, 1, url)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Fetch a single row by URL — used by the star toggle so it can find
    /// the row to delete or read its tag state.
    func bookmark(forURL url: String) -> Bookmark? {
        guard let db, !url.isEmpty else { return nil }
        let sql = """
        SELECT id, url, title, favicon_path, folder, created_at_iso, tags_json, description
        FROM bookmarks
        WHERE url = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindString(statement, 1, url)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readBookmark(statement)
    }

    /// Distinct list of every tag in the store, lowercased + sorted. Used
    /// to populate the sidebar's tag filter chips. Done in-process rather
    /// than in SQL because tags are JSON-encoded in a single column.
    func allTags() -> [String] {
        let rows = listBookmarks()
        var set: Set<String> = []
        for row in rows {
            for tag in row.tags {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty {
                    set.insert(trimmed)
                }
            }
        }
        return set.sorted()
    }

    /// Distinct list of folders. Empty-string folder (root) is filtered
    /// out so the tree shows only named folders.
    func allFolders() -> [String] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT folder FROM bookmarks ORDER BY folder ASC;", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var folders: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let folder = readString(statement, 0)
            if !folder.isEmpty {
                folders.append(folder)
            }
        }
        return folders
    }

    /// Total row count — used by the migration backfill's progress
    /// indicator and the settings empty-state.
    func count() -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM bookmarks;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Clears every tag + description across all rows. Used by the
    /// "Re-tag all bookmarks" settings button so the backfill picks them
    /// up again.
    func clearAllAITags() {
        guard let db else { return }
        sqlite3_exec(db, "UPDATE bookmarks SET tags_json = '[]', description = '';", nil, nil, nil)
        broadcastChange()
    }

    // MARK: - Schema + lifecycle

    private func open() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "BookmarksStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open bookmarks.sqlite at \(databaseURL.path)"
            ])
        }
        self.db = handle

        let schema = """
        CREATE TABLE IF NOT EXISTS bookmarks (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            favicon_path TEXT NOT NULL DEFAULT '',
            folder TEXT NOT NULL DEFAULT '',
            created_at_iso TEXT NOT NULL,
            tags_json TEXT NOT NULL DEFAULT '[]',
            description TEXT NOT NULL DEFAULT '',
            embedding BLOB
        );
        CREATE INDEX IF NOT EXISTS bookmarks_created_at ON bookmarks (created_at_iso DESC);
        CREATE INDEX IF NOT EXISTS bookmarks_folder ON bookmarks (folder);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
    }

    private func broadcastChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Decode helpers

    private func readBookmark(_ statement: OpaquePointer?) -> Bookmark {
        let id = readString(statement, 0)
        let url = readString(statement, 1)
        let title = readString(statement, 2)
        let favicon = readString(statement, 3)
        let folder = readString(statement, 4)
        let createdISO = readString(statement, 5)
        let tagsJSON = readString(statement, 6)
        let description = readString(statement, 7)
        let createdAt = Self.iso8601Formatter.date(from: createdISO) ?? Date()
        let tags = Self.decodeTags(tagsJSON)
        return Bookmark(
            id: id,
            url: url,
            title: title,
            faviconPath: favicon,
            folder: folder,
            createdAt: createdAt,
            tags: tags,
            descriptionText: description,
            isTagging: false
        )
    }

    private static func encodeTags(_ tags: [String]) -> String {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: cleaned, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decodeTags(_ json: String) -> [String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: []) as? [String] else {
            return []
        }
        return value
    }

    // MARK: - Bind / read helpers

    private func bindString(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
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
            print("BookmarksStore [\(context)]:", String(cString: messagePointer))
        }
        #endif
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
