import Foundation

/// A single entry in WebKit's declarative content-blocking format — a
/// `{ trigger, action }` pair. WebKit compiles an array of these into a
/// `WKContentRuleList` and evaluates them inside its networking process,
/// *before* a request leaves the device, which is what makes this far cheaper
/// (and harder to circumvent) than JS-based blocking.
///
/// Encoding maps Swift's camelCase onto the hyphenated JSON keys WebKit
/// expects (`url-filter`, `if-domain`, …). Optional fields are omitted when
/// nil — the synthesized `Encodable` uses `encodeIfPresent` — so a minimal
/// trigger serializes to just `{"url-filter": "…"}`.
///
/// Reference: Apple, "Creating a Content Blocker".
struct BlockRule: Encodable, Equatable {
    var trigger: Trigger
    var action: Action

    /// The match condition. `urlFilter` is the only field WebKit requires.
    struct Trigger: Encodable, Equatable {
        /// Regular expression — a WebKit-specific subset — matched against the
        /// full request URL.
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        /// Resource kinds the rule applies to. Nil means "every kind".
        var resourceType: [ResourceType]?
        /// First- vs third-party relative to the page being viewed. Tracker
        /// and ad rules pin this to `.thirdParty` so a site loading its own
        /// first-party assets is never touched.
        var loadType: [LoadType]?
        /// Page domains the rule is *limited* to. Mutually exclusive with
        /// `unlessDomain` in a single trigger, per WebKit.
        var ifDomain: [String]?
        /// Page domains the rule is *suppressed* on. This is how the per-site
        /// allowlist disables blocking — the compiler folds the allowlisted
        /// hosts in here rather than stripping rules away.
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    /// What WebKit does when a trigger matches.
    struct Action: Encodable, Equatable {
        var type: ActionType
        /// CSS selector for `.cssDisplayNone`; ignored by every other action.
        var selector: String?
    }

    enum ActionType: String, Encodable {
        case block
        case blockCookies = "block-cookies"
        case cssDisplayNone = "css-display-none"
        case ignorePreviousRules = "ignore-previous-rules"
        case makeHTTPS = "make-https"
    }

    /// WebKit's resource-type vocabulary. Spelled out so callers get
    /// compile-time checking instead of stringly-typed JSON.
    enum ResourceType: String, Encodable {
        case document
        case image
        case styleSheet = "style-sheet"
        case script
        case font
        case raw
        case svgDocument = "svg-document"
        case media
        case popup
        case ping
        case fetch
        case websocket
        case other
    }

    enum LoadType: String, Encodable {
        case firstParty = "first-party"
        case thirdParty = "third-party"
    }
}

// MARK: - Convenience builders

extension BlockRule {
    /// Blocks every *third-party* request whose host is `domain` or any
    /// subdomain of it. The filter is anchored at the scheme so it matches the
    /// host only — never a path or query string that merely mentions the
    /// domain — and `load-type: third-party` leaves a site's own first-party
    /// requests alone.
    static func blockThirdParty(host domain: String) -> BlockRule {
        BlockRule(
            trigger: Trigger(urlFilter: hostURLFilter(domain), loadType: [.thirdParty]),
            action: Action(type: .block)
        )
    }

    /// Hides DOM nodes matching `selector` on every page (subject to the
    /// allowlist). Used for cosmetic annoyance filtering — cookie bars and the
    /// like — where there is no network request to intercept.
    static func hide(selector: String) -> BlockRule {
        BlockRule(
            trigger: Trigger(urlFilter: ".*"),
            action: Action(type: .cssDisplayNone, selector: selector)
        )
    }

    /// Builds a host-anchored URL filter for `domain` and its subdomains.
    /// `^https?://` pins the match to the scheme; `([^/]+\.)?` optionally
    /// consumes leading subdomain labels without crossing a `/`, so the match
    /// can't escape into the path.
    static func hostURLFilter(_ domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]+\\.)?\(escaped)"
    }
}
