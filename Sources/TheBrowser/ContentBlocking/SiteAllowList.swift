import Foundation

/// The set of sites where the user has switched blocking off, stored as
/// normalized hosts (lowercased, `www.`-stripped, scheme/path/port removed).
///
/// It produces the `unless-domain` patterns ``ContentRuleCompiler`` folds into
/// every rule, so blocking is suppressed on these pages without deleting any
/// rules — flip a site back on and the next recompile restores full blocking.
struct SiteAllowList: Codable, Equatable {
    private(set) var domains: Set<String>

    init(domains: Set<String> = []) {
        self.domains = domains
    }

    var sortedDomains: [String] { domains.sorted() }
    var isEmpty: Bool { domains.isEmpty }

    /// WebKit `unless-domain` patterns. The leading `*` makes each entry match
    /// the domain *and* all of its subdomains.
    var unlessDomainPatterns: [String] {
        domains.sorted().map { "*\($0)" }
    }

    /// True when `host` is allowlisted directly or sits under an allowlisted
    /// parent domain (`secure.example.com` is covered by `example.com`).
    func contains(_ host: String) -> Bool {
        guard let normalized = Self.normalize(host) else { return false }
        return domains.contains { normalized == $0 || normalized.hasSuffix("." + $0) }
    }

    mutating func insert(_ hostOrURL: String) {
        guard let normalized = Self.normalize(hostOrURL) else { return }
        domains.insert(normalized)
    }

    mutating func remove(_ host: String) {
        // Remove by exact normalized key so the Settings list round-trips, and
        // also drop any covering parent so an explicit removal really sticks.
        guard let normalized = Self.normalize(host) else { return }
        domains.remove(normalized)
    }

    /// Reduces a host or full URL to a bare lowercased host: strips scheme,
    /// path, port, and a leading `www.`. Returns nil when nothing host-like
    /// remains (no dot, or embedded whitespace).
    static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }

        if let parsed = URL(string: host), let parsedHost = parsed.host {
            host = parsedHost
        } else {
            if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        }

        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host.contains("."), !host.contains(" ") else { return nil }
        return host
    }
}
