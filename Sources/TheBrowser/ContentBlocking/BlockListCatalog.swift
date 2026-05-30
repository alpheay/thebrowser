import Foundation

/// The built-in, offline-by-default block lists. Curated rather than mirrored
/// from a huge upstream list (EasyList et al.) so the feature works on a fresh
/// launch with no network round-trip and a small, auditable rule set. Each
/// entry is a well-known third-party host; the rules block them only as
/// third-party requests, so a site loading its own assets is unaffected.
///
/// The catalog is intentionally static data — no allowlist, no preferences.
/// ``ContentRuleCompiler`` folds the per-site allowlist in at compile time, and
/// ``ContentBlockingController`` decides which categories are live.
enum BlockListCatalog {
    /// Every bundled list, one per category.
    static func defaultLists() -> [BlockList] {
        [adsList(), trackersList(), cookiesList(), annoyancesList(), socialList()]
    }

    static func adsList() -> BlockList {
        BlockList(
            id: "thebrowser.ads",
            name: "Ad Networks",
            category: .ads,
            source: "Bundled",
            rules: adDomains.map(BlockRule.blockThirdParty(host:))
        )
    }

    static func trackersList() -> BlockList {
        BlockList(
            id: "thebrowser.trackers",
            name: "Trackers & Analytics",
            category: .trackers,
            source: "Bundled",
            rules: trackerDomains.map(BlockRule.blockThirdParty(host:))
        )
    }

    static func cookiesList() -> BlockList {
        BlockList(
            id: "thebrowser.third-party-cookies",
            name: "Third-party Cookies",
            category: .cookies,
            source: "Bundled",
            rules: [.blockThirdPartyCookies()]
        )
    }

    static func socialList() -> BlockList {
        BlockList(
            id: "thebrowser.social",
            name: "Social Widgets",
            category: .social,
            source: "Bundled",
            rules: socialDomains.map(BlockRule.blockThirdParty(host:))
        )
    }

    /// Cosmetic list: one `css-display-none` rule hiding the union of common
    /// consent-banner containers. A single combined selector keeps it to one
    /// rule rather than dozens.
    static func annoyancesList() -> BlockList {
        BlockList(
            id: "thebrowser.annoyances",
            name: "Cookie & Consent Banners",
            category: .annoyances,
            source: "Bundled",
            rules: [BlockRule.hide(selector: cookieBannerSelectors.joined(separator: ", "))]
        )
    }

    // MARK: - Curated domain sets

    /// Ad-serving and ad-exchange hosts.
    static let adDomains: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "googletagservices.com",
        "2mdn.net",
        "amazon-adsystem.com",
        "adnxs.com",
        "adsrvr.org",
        "rubiconproject.com",
        "pubmatic.com",
        "openx.net",
        "criteo.com",
        "criteo.net",
        "taboola.com",
        "outbrain.com",
        "moatads.com",
        "adcolony.com",
        "applovin.com",
        "inmobi.com",
        "smartadserver.com",
        "casalemedia.com",
        "contextweb.com",
        "bidswitch.net",
        "3lift.com",
        "sharethrough.com",
        "teads.tv",
        "yieldmo.com",
        "adform.net",
        "media.net",
        "advertising.com",
        "serving-sys.com",
        "spotxchange.com",
        "indexww.com",
        "gumgum.com"
    ]

    /// Analytics, attribution, and cross-site tracking hosts.
    static let trackerDomains: [String] = [
        "google-analytics.com",
        "googletagmanager.com",
        "scorecardresearch.com",
        "quantserve.com",
        "quantcount.com",
        "hotjar.com",
        "mouseflow.com",
        "fullstory.com",
        "mixpanel.com",
        "segment.com",
        "segment.io",
        "amplitude.com",
        "heap.io",
        "heapanalytics.com",
        "chartbeat.com",
        "nr-data.net",
        "branch.io",
        "adjust.com",
        "appsflyer.com",
        "kochava.com",
        "crazyegg.com",
        "optimizely.com",
        "omtrdc.net",
        "demdex.net",
        "everesttech.net",
        "bluekai.com",
        "krxd.net",
        "agkn.com",
        "rlcdn.com",
        "crwdcntrl.net",
        "exelator.com",
        "mathtag.com",
        "tapad.com",
        "sharethis.com",
        "parsely.com",
        "yieldlab.net"
    ]

    /// Social-network widget, embed, and pixel hosts. Kept off by default —
    /// blocking these can also strip wanted embeds (tweets, posts).
    static let socialDomains: [String] = [
        "connect.facebook.net",
        "platform.twitter.com",
        "syndication.twitter.com",
        "platform.linkedin.com",
        "snap.licdn.com",
        "px.ads.linkedin.com",
        "widgets.pinterest.com",
        "assets.pinterest.com",
        "platform.instagram.com",
        "apis.google.com",
        "plusone.google.com",
        "buttons.reddit.com",
        "static.addtoany.com"
    ]

    /// CSS selectors for the most common consent / cookie-banner containers.
    /// Conservative on purpose — only library-specific IDs and classes that
    /// are very unlikely to collide with real content.
    static let cookieBannerSelectors: [String] = [
        "#onetrust-banner-sdk",
        "#onetrust-consent-sdk",
        "#CybotCookiebotDialog",
        ".cc-window",
        "#cookie-law-info-bar",
        "#gdpr-cookie-message",
        ".qc-cmp2-container",
        "#usercentrics-root",
        ".fc-consent-root",
        "#didomi-host",
        ".osano-cm-window",
        "#hs-eu-cookie-confirmation",
        "#truste-consent-track",
        ".cookie-notice-container"
    ]
}
