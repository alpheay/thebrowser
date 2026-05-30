import Foundation

/// The persisted shape of the user's content-blocking choices: the master
/// switch, which categories are on, and the per-site allowlist.
///
/// Stored as a single JSON blob under one `UserDefaults` key (see
/// ``PreferenceKey/contentBlocking``) so adding a field later never needs a new
/// key or a defaults migration — an older blob just decodes with the new field
/// missing and falls back to ``defaults``.
struct ContentBlockingPreferences: Codable, Equatable {
    static let currentSchemaVersion = 2

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case enabledCategories
        case allowList
        case popupBlockingEnabled
        case popupAllowList
        case stripTrackingParameters
    }

    var schemaVersion: Int
    var isEnabled: Bool
    /// Category raw values that are switched on. Stored as strings so an
    /// unknown future category in an old blob decodes harmlessly.
    var enabledCategories: Set<String>
    var allowList: SiteAllowList
    var popupBlockingEnabled: Bool
    var popupAllowList: SiteAllowList
    var stripTrackingParameters: Bool

    /// Fresh-install state: master on, default-on categories enabled, empty
    /// allowlist.
    static var defaults: ContentBlockingPreferences {
        ContentBlockingPreferences(
            schemaVersion: currentSchemaVersion,
            isEnabled: true,
            enabledCategories: Set(BlockListCategory.allCases.filter(\.isOnByDefault).map(\.id)),
            allowList: SiteAllowList(),
            popupBlockingEnabled: true,
            popupAllowList: SiteAllowList(),
            stripTrackingParameters: true
        )
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        isEnabled: Bool,
        enabledCategories: Set<String>,
        allowList: SiteAllowList,
        popupBlockingEnabled: Bool = true,
        popupAllowList: SiteAllowList = SiteAllowList(),
        stripTrackingParameters: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.enabledCategories = enabledCategories
        self.allowList = allowList
        self.popupBlockingEnabled = popupBlockingEnabled
        self.popupAllowList = popupAllowList
        self.stripTrackingParameters = stripTrackingParameters
    }

    init(from decoder: Decoder) throws {
        let fallback = Self.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        enabledCategories = try container.decodeIfPresent(Set<String>.self, forKey: .enabledCategories) ?? fallback.enabledCategories
        allowList = try container.decodeIfPresent(SiteAllowList.self, forKey: .allowList) ?? fallback.allowList
        popupBlockingEnabled = try container.decodeIfPresent(Bool.self, forKey: .popupBlockingEnabled) ?? fallback.popupBlockingEnabled
        popupAllowList = try container.decodeIfPresent(SiteAllowList.self, forKey: .popupAllowList) ?? fallback.popupAllowList
        stripTrackingParameters = try container.decodeIfPresent(Bool.self, forKey: .stripTrackingParameters) ?? fallback.stripTrackingParameters

        schemaVersion = Self.currentSchemaVersion
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
