import Foundation

/// The persisted shape of the user's content-blocking choices: the master
/// switch, which categories are on, and the per-site allowlist.
///
/// Stored as a single JSON blob under one `UserDefaults` key (see
/// ``PreferenceKey/contentBlocking``) so adding a field later never needs a new
/// key or a defaults migration — an older blob just decodes with the new field
/// missing and falls back to ``defaults``.
struct ContentBlockingPreferences: Codable, Equatable {
    var isEnabled: Bool
    /// Category raw values that are switched on. Stored as strings so an
    /// unknown future category in an old blob decodes harmlessly.
    var enabledCategories: Set<String>
    var allowList: SiteAllowList

    /// Fresh-install state: master on, default-on categories enabled, empty
    /// allowlist.
    static var defaults: ContentBlockingPreferences {
        ContentBlockingPreferences(
            isEnabled: true,
            enabledCategories: Set(BlockListCategory.allCases.filter(\.isOnByDefault).map(\.id)),
            allowList: SiteAllowList()
        )
    }

    func isEnabled(_ category: BlockListCategory) -> Bool {
        enabledCategories.contains(category.id)
    }

    mutating func setCategory(_ category: BlockListCategory, enabled: Bool) {
        if enabled {
            enabledCategories.insert(category.id)
        } else {
            enabledCategories.remove(category.id)
        }
    }
}

extension ContentBlockingPreferences {
    /// Loads from `UserDefaults`, falling back to ``defaults`` when nothing is
    /// stored or the blob can't be decoded (e.g. a schema from a future build).
    static func load(
        from defaults: UserDefaults = .standard,
        key: String = PreferenceKey.contentBlocking
    ) -> ContentBlockingPreferences {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(ContentBlockingPreferences.self, from: data)
        else {
            return .defaults
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard, key: String = PreferenceKey.contentBlocking) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
