import Foundation

/// Removes common cross-site attribution parameters from top-level navigations.
/// This deliberately stays conservative: only known marketing/click IDs and
/// `utm_*` tags are stripped, while ordinary query parameters are preserved.
enum URLTrackingSanitizer {
    private static let exactNames: Set<String> = [
        "dclid",
        "fbclid",
        "gbraid",
        "gclid",
        "gclsrc",
        "igshid",
        "li_fat_id",
        "mc_cid",
        "mc_eid",
        "msclkid",
        "ob_click_id",
        "rb_clickid",
        "scid",
        "ttclid",
        "twclid",
        "wbraid",
        "yclid"
    ]

    static func sanitized(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return url
        }

        let filtered = queryItems.filter { !isTrackingParameter($0.name) }
        guard filtered.count != queryItems.count else { return url }

        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.url ?? url
    }

    static func isTrackingParameter(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("utm_") || exactNames.contains(lowercased)
    }
}
