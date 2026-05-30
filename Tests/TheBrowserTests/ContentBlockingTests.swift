import Foundation
import Testing
@testable import TheBrowser

@Suite("BlockRule encoding")
struct BlockRuleTests {
    /// Decodes a single rule's encoded JSON back into a dictionary so tests can
    /// assert on the exact WebKit keys.
    private func encodedRule(_ rule: BlockRule) throws -> [String: Any] {
        let json = try ContentRuleCompiler.encode([rule], unlessDomain: [])
        let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        return try #require(array?.first)
    }

    @Test("Third-party block rule encodes WebKit keys")
    func thirdPartyEncoding() throws {
        let dict = try encodedRule(.blockThirdParty(host: "doubleclick.net"))
        let trigger = try #require(dict["trigger"] as? [String: Any])
        let action = try #require(dict["action"] as? [String: Any])

        #expect(trigger["url-filter"] as? String == "^https?://([^/]+\\.)?doubleclick\\.net([/:?#]|$)")
        #expect(trigger["load-type"] as? [String] == ["third-party"])
        #expect(action["type"] as? String == "block")
        // Optional fields stay absent when nil.
        #expect(trigger["unless-domain"] == nil)
        #expect(action["selector"] == nil)
    }

    @Test("Cosmetic hide rule carries a selector and a catch-all filter")
    func hideEncoding() throws {
        let dict = try encodedRule(.hide(selector: ".cookie-bar"))
        let trigger = try #require(dict["trigger"] as? [String: Any])
        let action = try #require(dict["action"] as? [String: Any])

        #expect(trigger["url-filter"] as? String == ".*")
        #expect(action["type"] as? String == "css-display-none")
        #expect(action["selector"] as? String == ".cookie-bar")
    }

    @Test("Host filter anchors at the scheme and escapes dots")
    func hostFilter() {
        #expect(BlockRule.hostURLFilter("ads.example.co.uk") == "^https?://([^/]+\\.)?ads\\.example\\.co\\.uk([/:?#]|$)")
    }

    @Test("Host filter matches only real host boundaries")
    func hostFilterBoundaries() {
        let pattern = BlockRule.hostURLFilter("doubleclick.net")
        let matching = [
            "https://doubleclick.net",
            "https://doubleclick.net/ad.js",
            "https://doubleclick.net:443/ad.js",
            "https://doubleclick.net?slot=1",
            "https://foo.doubleclick.net/ad.js"
        ]
        let nonMatching = [
            "https://doubleclick.net.evil.test/ad.js",
            "https://notdoubleclick.net/ad.js",
            "https://example.com/path/doubleclick.net/ad.js"
        ]

        for url in matching {
            #expect(url.range(of: pattern, options: .regularExpression) != nil)
        }
        for url in nonMatching {
            #expect(url.range(of: pattern, options: .regularExpression) == nil)
        }
    }
}

@Suite("BlockListCatalog")
struct BlockListCatalogTests {
    @Test("Ships one list per category with unique identifiers")
    func defaultLists() {
        let lists = BlockListCatalog.defaultLists()
        #expect(lists.count == BlockListCategory.allCases.count)
        #expect(Set(lists.map(\.id)).count == lists.count)
        #expect(Set(lists.map(\.category)) == Set(BlockListCategory.allCases))
    }

    @Test("Every list contributes at least one rule")
    func nonEmpty() {
        for list in BlockListCatalog.defaultLists() {
            #expect(list.ruleCount > 0)
        }
    }

    @Test("Curated sets cover the obvious offenders")
    func wellKnownDomains() {
        #expect(BlockListCatalog.adDomains.contains("doubleclick.net"))
        #expect(BlockListCatalog.trackerDomains.contains("google-analytics.com"))
        #expect(BlockListCatalog.socialDomains.contains("connect.facebook.net"))
    }

    @Test("Annoyances list is a single combined cosmetic rule")
    func annoyancesShape() {
        let list = BlockListCatalog.annoyancesList()
        #expect(list.rules.count == 1)
        #expect(list.rules.first?.action.type == .cssDisplayNone)
    }

    @Test("No domain appears in more than one network list")
    func noCrossListDuplicates() {
        let network = BlockListCatalog.adDomains + BlockListCatalog.trackerDomains + BlockListCatalog.socialDomains
        #expect(Set(network).count == network.count)
    }
}

@Suite("BlockListCategory")
struct BlockListCategoryTests {
    @Test("Ads and trackers default on; annoyances and social are opt-in")
    func defaults() {
        #expect(BlockListCategory.ads.isOnByDefault)
        #expect(BlockListCategory.trackers.isOnByDefault)
        #expect(!BlockListCategory.annoyances.isOnByDefault)
        #expect(!BlockListCategory.social.isOnByDefault)
    }

    @Test("Every category has presentable metadata")
    func metadata() {
        for category in BlockListCategory.allCases {
            #expect(!category.title.isEmpty)
            #expect(!category.detail.isEmpty)
            #expect(!category.symbolName.isEmpty)
        }
    }
}

@Suite("SiteAllowList")
struct SiteAllowListTests {
    @Test(
        "Normalize strips scheme, www, path, and port",
        arguments: [
            ("https://www.Example.com/path?q=1", "example.com"),
            ("www.example.com", "example.com"),
            ("EXAMPLE.com", "example.com"),
            ("example.com:8080", "example.com"),
            ("  example.com  ", "example.com")
        ]
    )
    func normalizeReduces(input: String, expected: String) {
        #expect(SiteAllowList.normalize(input) == expected)
    }

    @Test(
        "Normalize rejects non-hosts",
        arguments: ["localhost", "not a domain", "", "   "]
    )
    func normalizeRejects(input: String) {
        #expect(SiteAllowList.normalize(input) == nil)
    }

    @Test("Subdomains are covered by an allowlisted parent")
    func subdomainCoverage() {
        var list = SiteAllowList()
        list.insert("example.com")
        #expect(list.contains("example.com"))
        #expect(list.contains("secure.example.com"))
        #expect(!list.contains("notexample.com"))
        // A lookalike that merely ends in the literal name is not covered.
        #expect(!list.contains("example.com.evil.com"))
    }

    @Test("Patterns get a wildcard prefix for WebKit's unless-domain")
    func patterns() {
        let list = SiteAllowList(domains: ["b.com", "a.com"])
        #expect(list.unlessDomainPatterns == ["*a.com", "*b.com"])
    }

    @Test("Insert dedupes via normalization; remove clears it")
    func insertRemove() {
        var list = SiteAllowList()
        list.insert("https://WWW.Example.com/")
        list.insert("example.com")
        #expect(list.domains == ["example.com"])
        list.remove("example.com")
        #expect(list.isEmpty)
    }
}

@Suite("ContentBlockingPreferences")
struct ContentBlockingPreferencesTests {
    @Test("Defaults enable blocking with the default-on categories")
    func defaults() {
        let prefs = ContentBlockingPreferences.defaults
        #expect(prefs.schemaVersion == ContentBlockingPreferences.currentSchemaVersion)
        #expect(prefs.isEnabled)
        #expect(prefs.isEnabled(.ads))
        #expect(prefs.isEnabled(.trackers))
        #expect(!prefs.isEnabled(.annoyances))
        #expect(prefs.allowList.isEmpty)
        #expect(prefs.popupBlockingEnabled)
        #expect(prefs.popupAllowList.isEmpty)
        #expect(prefs.stripTrackingParameters)
    }

    @Test("setCategory flips membership")
    func categoryToggle() {
        var prefs = ContentBlockingPreferences.defaults
        prefs.setCategory(.ads, enabled: false)
        #expect(!prefs.isEnabled(.ads))
        prefs.setCategory(.annoyances, enabled: true)
        #expect(prefs.isEnabled(.annoyances))
    }

    @Test("Codable round-trips through JSON")
    func roundTrip() throws {
        var prefs = ContentBlockingPreferences.defaults
        prefs.allowList.insert("example.com")
        prefs.popupAllowList.insert("popups.example")
        prefs.setCategory(.social, enabled: true)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ContentBlockingPreferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test("Legacy blobs fill missing privacy fields")
    func legacyDecode() throws {
        let data = Data("""
        {
          "isEnabled": true,
          "enabledCategories": ["ads"],
          "allowList": { "domains": ["example.com"] }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ContentBlockingPreferences.self, from: data)

        #expect(decoded.schemaVersion == ContentBlockingPreferences.currentSchemaVersion)
        #expect(decoded.enabledCategories == ["ads"])
        #expect(decoded.allowList.contains("www.example.com"))
        #expect(decoded.popupBlockingEnabled)
        #expect(decoded.popupAllowList.isEmpty)
        #expect(decoded.stripTrackingParameters)
    }

    @Test("Load falls back to defaults when storage is empty")
    func loadFallback() {
        let suite = "test.contentBlocking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ContentBlockingPreferences.load(from: defaults, key: "absent") == .defaults)
    }

    @Test("Save then load survives a round-trip through UserDefaults")
    func saveLoad() {
        let suite = "test.contentBlocking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var prefs = ContentBlockingPreferences.defaults
        prefs.isEnabled = false
        prefs.allowList.insert("example.com")
        prefs.save(to: defaults, key: "blob")

        let loaded = ContentBlockingPreferences.load(from: defaults, key: "blob")
        #expect(loaded == prefs)
    }
}

@Suite("ContentRuleCompiler encoding")
struct ContentRuleCompilerTests {
    private func triggers(_ json: String) throws -> [[String: Any]] {
        let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        return try #require(array).map { try #require($0["trigger"] as? [String: Any]) }
    }

    @Test("Allowlist patterns are folded into every trigger")
    func injectsUnlessDomain() throws {
        let rules = [BlockRule.blockThirdParty(host: "a.com"), .blockThirdParty(host: "b.com")]
        let json = try ContentRuleCompiler.encode(rules, unlessDomain: ["*allowed.com"])
        for trigger in try triggers(json) {
            #expect(trigger["unless-domain"] as? [String] == ["*allowed.com"])
        }
    }

    @Test("Empty allowlist leaves triggers untouched")
    func noUnlessDomainWhenEmpty() throws {
        let json = try ContentRuleCompiler.encode([.blockThirdParty(host: "a.com")], unlessDomain: [])
        #expect(try triggers(json).allSatisfy { $0["unless-domain"] == nil })
    }

    @Test("Cache identifier is the bare id with no allowlist")
    func identifierWithoutAllowlist() {
        let list = BlockListCatalog.adsList()
        #expect(ContentRuleCompiler.cacheIdentifier(for: list, allowlistPatterns: []) == list.id)
    }

    @Test("Cache identifier is order-independent and allowlist-sensitive")
    func identifierStability() {
        let list = BlockListCatalog.adsList()
        let a = ContentRuleCompiler.cacheIdentifier(for: list, allowlistPatterns: ["*a.com", "*b.com"])
        let b = ContentRuleCompiler.cacheIdentifier(for: list, allowlistPatterns: ["*b.com", "*a.com"])
        let c = ContentRuleCompiler.cacheIdentifier(for: list, allowlistPatterns: ["*c.com"])
        #expect(a == b)
        #expect(a != c)
        #expect(a != list.id)
    }
}
