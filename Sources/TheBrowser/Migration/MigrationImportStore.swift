import Foundation

enum MigrationImportStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let bookmarkLimit = 2_000
    private static let historyLimit = 5_000

    static func save(payload: BrowserMigrationPayload, result: MigrationResult) {
        let bookmarks = merged(
            existing: importedBookmarks(limit: bookmarkLimit),
            incoming: payload.bookmarks,
            limit: bookmarkLimit
        )
        let history = merged(
            existing: importedHistory(limit: historyLimit),
            incoming: payload.history,
            limit: historyLimit
        )

        save(bookmarks, forKey: PreferenceKey.migrationImportedBookmarks)
        save(history, forKey: PreferenceKey.migrationImportedHistory)
        save(result, forKey: PreferenceKey.migrationLastResult)
    }

    static func importedBookmarks(limit: Int) -> [ImportedBookmark] {
        loadArray([ImportedBookmark].self, forKey: PreferenceKey.migrationImportedBookmarks)
            .prefix(limit)
            .map { $0 }
    }

    static func importedHistory(limit: Int) -> [ImportedHistoryEntry] {
        loadArray([ImportedHistoryEntry].self, forKey: PreferenceKey.migrationImportedHistory)
            .prefix(limit)
            .map { $0 }
    }

    static func lastResult() -> MigrationResult? {
        loadOptional(MigrationResult.self, forKey: PreferenceKey.migrationLastResult)
    }

    private static func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadArray<Value: Decodable>(_ type: [Value].Type, forKey key: String) -> [Value] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? decoder.decode(type, from: data) else {
            return []
        }
        return value
    }

    private static func loadOptional<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? decoder.decode(type, from: data) else {
            return nil
        }
        return value
    }

    private static func merged<Item: Identifiable & Hashable>(
        existing: [Item],
        incoming: [Item],
        limit: Int
    ) -> [Item] where Item.ID == String {
        var seen = Set<String>()
        var mergedItems: [Item] = []

        for item in incoming + existing {
            guard seen.insert(item.id).inserted else { continue }
            mergedItems.append(item)
            if mergedItems.count == limit { break }
        }

        return mergedItems
    }
}
