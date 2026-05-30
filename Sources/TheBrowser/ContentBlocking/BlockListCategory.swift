import Foundation

/// The kind of nuisance a block list targets. Categories are the unit the user
/// toggles in Settings, and each maps to exactly one compiled
/// `WKContentRuleList` at runtime.
///
/// Raw values are stable identifiers: they're persisted in preferences and
/// reused as part of the WebKit rule-list identifier. Don't rename them.
enum BlockListCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case ads
    case trackers
    case annoyances
    case social

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ads: "Advertising"
        case .trackers: "Trackers & Analytics"
        case .annoyances: "Annoyances"
        case .social: "Social Widgets"
        }
    }

    var detail: String {
        switch self {
        case .ads:
            "Block ad networks — the requests that fetch banners, pop-ups, and video pre-rolls."
        case .trackers:
            "Stop analytics, fingerprinting, and cross-site tracking beacons from loading."
        case .annoyances:
            "Hide cookie-consent bars and other on-page clutter. May affect site layout."
        case .social:
            "Block share buttons and embeds that report your browsing back to social networks."
        }
    }

    var symbolName: String {
        switch self {
        case .ads: "rectangle.slash"
        case .trackers: "eye.slash"
        case .annoyances: "hand.raised"
        case .social: "bubble.left.and.bubble.right"
        }
    }

    /// Whether the category is on for a fresh install. Ads and trackers — the
    /// headline feature — default on. Cosmetic annoyance filtering and social
    /// blocking are the two most likely to break a page's layout or hide a
    /// wanted embed, so they're opt-in.
    var isOnByDefault: Bool {
        switch self {
        case .ads, .trackers: true
        case .annoyances, .social: false
        }
    }
}
