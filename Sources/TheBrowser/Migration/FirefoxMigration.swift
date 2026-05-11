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
