import Foundation

/// Snapshot of the user's Inline Completions preferences. Read fresh on
/// every request so settings changes propagate without re-injecting the
/// shim.
struct InlineCompletionsSettings: Sendable, Equatable {
    var isEnabled: Bool
    var triggerDelayMs: Int
    var renderMode: String
    var allowList: [String]
    var blockList: [String]

    static func current(defaults: UserDefaults = .standard) -> InlineCompletionsSettings {
        let rawDelay = defaults.object(forKey: PreferenceKey.inlineCompletionsTriggerDelayMs) as? Int ?? 600
        let clampedDelay = max(200, min(2000, rawDelay))
        let mode = defaults.string(forKey: PreferenceKey.inlineCompletionsRenderMode) ?? "ghost"

        return InlineCompletionsSettings(
            isEnabled: defaults.object(forKey: PreferenceKey.inlineCompletionsEnabled) as? Bool ?? true,
            triggerDelayMs: clampedDelay,
            renderMode: mode == "popover" ? "popover" : "ghost",
            allowList: parseHostList(defaults.string(forKey: PreferenceKey.inlineCompletionsAllowList) ?? ""),
            blockList: parseHostList(defaults.string(forKey: PreferenceKey.inlineCompletionsBlockList) ?? "")
        )
    }

    /// Block list wins over allow list. An empty allow list means "every
    /// host is allowed unless explicitly blocked" — keeps the feature
    /// useful for sites the user hasn't manually opted into yet.
    func allows(host: String) -> Bool {
        guard isEnabled else { return false }
        let normalized = host.lowercased()
        guard !normalized.isEmpty else { return false }
        if blockList.contains(where: { hostMatches(normalized, suffix: $0) }) {
            return false
        }
        if allowList.isEmpty {
            return true
        }
        return allowList.contains(where: { hostMatches(normalized, suffix: $0) })
    }

    private func hostMatches(_ host: String, suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }

    private static func parseHostList(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

extension InlineCompletionsSettings {
    static let defaultAllowList: [String] = [
        "mail.google.com",
        "github.com",
        "linear.app",
        "slack.com",
        "app.slack.com",
        "notion.so",
        "hey.com",
        "fastmail.com",
        "x.com",
        "twitter.com",
        "reddit.com"
    ]

    static let defaultAllowListString: String = defaultAllowList.joined(separator: "\n")
}
