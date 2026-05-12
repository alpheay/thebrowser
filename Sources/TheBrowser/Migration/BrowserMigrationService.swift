import Foundation

protocol BrowserMigrating {
    var source: MigrationSource { get }
    func profiles() -> [BrowserProfile]
    func migrate(profile: BrowserProfile) throws -> BrowserMigrationPayload
}

enum BrowserMigratorFactory {
    static func migrator(for source: MigrationSource) -> BrowserMigrating {
        switch source {
        case .chrome:
            ChromeMigration()
        case .firefox:
            FirefoxMigration()
        }
    }
}

enum BrowserMigrationService {
    static func profiles(for source: MigrationSource) -> [BrowserProfile] {
        BrowserMigratorFactory.migrator(for: source).profiles()
    }

    static func migrate(source: MigrationSource, profile: BrowserProfile) async throws -> MigrationResult {
        let migrator = BrowserMigratorFactory.migrator(for: source)
        var payload = try migrator.migrate(profile: profile)
        payload.bookmarks = uniqueBookmarks(payload.bookmarks)
        payload.history = uniqueHistory(payload.history)

        let counts = MigrationCounts(
            bookmarks: payload.bookmarks.count,
            history: payload.history.count
        )
        let result = MigrationResult(
            source: source,
            profileName: profile.name,
            counts: counts,
            warnings: payload.warnings,
            completedAt: Date()
        )

        MigrationImportStore.save(payload: payload, result: result)
        let importedBookmarks = payload.bookmarks
        await MainActor.run {
            BookmarksManager.shared.ingestMigratedBookmarks(importedBookmarks)
        }
        return result
    }

    private static func uniqueBookmarks(_ bookmarks: [ImportedBookmark]) -> [ImportedBookmark] {
        var seen = Set<String>()
        return bookmarks.filter { bookmark in
            seen.insert(bookmark.url).inserted
        }
    }

    private static func uniqueHistory(_ history: [ImportedHistoryEntry]) -> [ImportedHistoryEntry] {
        var seen = Set<String>()
        return history.filter { entry in
            seen.insert(entry.url).inserted
        }
    }
}
