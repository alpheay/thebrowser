import Foundation

/// Privacy-side gate for the cited clipboard. Decides whether a tab's host
/// is on the user's blocklist, and ships a small starter list of obviously
/// sensitive domains. Suffix matching means an entry like `bankofamerica.com`
/// covers `secure.bankofamerica.com` and any other subdomain.
enum CitedClipboardPolicy {
    /// Default starter blocklist: a tiny, conservative set of obviously
    /// sensitive categories. Users can extend or replace this in Settings.
    static let defaultBlocklist: [String] = [
        // Banking
        "chase.com",
        "bankofamerica.com",
        "wellsfargo.com",
        "capitalone.com",
        "citi.com",
        "ally.com",
        // Healthcare
        "mychart.com",
        "kaiserpermanente.org",
        "healthcare.gov",
        // Password managers
        "1password.com",
        "lastpass.com",
        "bitwarden.com",
        // Auth surfaces — capturing snippets here is rarely useful and
        // sometimes leaks codes.
        "accounts.google.com",
        "login.microsoftonline.com",
        "appleid.apple.com"
    ]

    /// Encodes the default blocklist for ``UserDefaults`` registration.
    static var defaultBlocklistString: String {
        defaultBlocklist.joined(separator: "\n")
    }

    /// Parses the multi-line blocklist string from Settings into a normalized
    /// list of host suffixes. Blank lines and comments (`# ...`) are skipped.
    static func parseBlocklist(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Returns true when `host` is empty (no host = no clipboard capture
    /// allowed) or matches any blocklist entry by exact equality or as a
    /// suffix preceded by a dot.
    static func isBlocked(host: String, blocklist: [String]) -> Bool {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return true }
        for entry in blocklist {
            if normalizedHost == entry { return true }
            if normalizedHost.hasSuffix("." + entry) { return true }
        }
        return false
    }

    /// Convenience overload that pulls the user's blocklist out of
    /// ``UserDefaults``. Falls back to the default starter list when the key
    /// hasn't been set.
    static func isBlocked(host: String, defaults: UserDefaults = .standard) -> Bool {
        let raw = defaults.string(forKey: PreferenceKey.clipboardBlocklist) ?? defaultBlocklistString
        return isBlocked(host: host, blocklist: parseBlocklist(raw))
    }
}
