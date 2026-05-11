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
        payload.bookmarks = importBookmarks(from: profile.path)
        payload.history = try importHistory(from: profile.path)
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
}

private struct ChromeHistoryRow: Decodable {
    var title: String
    var url: String
    var visit_count: Int
    var last_visit_time: Int64
}
