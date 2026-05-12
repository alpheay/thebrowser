import Foundation

enum PreferenceKey {
    static let aiProvider = "ai.provider"
    static let aiWorkspacePath = "ai.workspacePath"
    static let aiModel = "ai.model"
    static let aiSystemPrompt = "ai.systemPrompt"
    static let aiTools = "ai.tools"
    static let aiAllowedTools = "ai.allowedTools"
    static let aiDisallowedTools = "ai.disallowedTools"
    static let aiMCPConfigPath = "ai.mcpConfigPath"
    static let aiExtraArguments = "ai.extraArguments"
    static let aiFavoriteModels = "ai.favoriteModels"
    static let aiShowToolChain = "ai.showToolChain"
    static let codexCLIPath = "codex.cliPath"
    static let codexWorkspacePath = "codex.workspacePath"
    static let codexModel = "codex.model"
    static let codexSandbox = "codex.sandbox"
    static let claudeCLIPath = "claude.cliPath"
    static let searchEngine = "browser.searchEngine"
    static let migrationPromptCompleted = "migration.promptCompleted"
    static let migrationImportedBookmarks = "migration.importedBookmarks"
    static let migrationImportedHistory = "migration.importedHistory"
    static let migrationLastResult = "migration.lastResult"
    static let toggleChatShortcut = "shortcut.toggleChat"
    static let toggleTabsShortcut = "shortcut.toggleTabs"
    static let newTabShortcut = "shortcut.newTab"
    static let closeTabShortcut = "shortcut.closeTab"
    static let focusAddressShortcut = "shortcut.focusAddress"
    static let smartReadShortcut = "shortcut.smartRead"
    static let readerModeShortcut = "shortcut.readerMode"
    static let pasteWithCitationShortcut = "shortcut.pasteWithCitation"
    static let googleOAuthClientID = "google.oauth.clientID"
    static let discordOAuthClientID = "discord.oauth.clientID"
    static let openDiscordShortcut = "shortcut.openDiscord"
    static let clipboardEnabled = "clipboard.enabled"
    static let clipboardSmartPasteEnabled = "clipboard.smartPasteEnabled"
    static let clipboardMarkdownStyle = "clipboard.markdownStyle"
    static let clipboardCitationStyle = "clipboard.citationStyle"
    static let clipboardBlocklist = "clipboard.blocklist"
    static let clipboardAppOverrides = "clipboard.appOverrides"
    static let notificationCorner = "notifications.corner"
    static let notificationsWelcomeShown = "notifications.welcomeShown"
    static let hoverPreviewEnabled = "hoverPreview.enabled"
    static let hoverPreviewModifier = "hoverPreview.modifier"
    static let hoverPreviewDelayMs = "hoverPreview.hoverDelayMs"
    static let hoverPreviewPrefetchDelayMs = "hoverPreview.prefetchDelayMs"
    static let hoverPreviewPrefetchBlocklist = "hoverPreview.prefetchBlocklist"
    static let toolbarShowBack = "toolbar.showBack"
    static let toolbarShowForward = "toolbar.showForward"
    static let toolbarShowReload = "toolbar.showReload"
    static let toolbarShowReaderMode = "toolbar.showReaderMode"
    static let toolbarShowSmartRead = "toolbar.showSmartRead"
    static let toolbarShowClipboard = "toolbar.showClipboard"
    static let toolbarShowTabRailToggle = "toolbar.showTabRailToggle"
    static let toolbarShowChatToggle = "toolbar.showChatToggle"
    /// Minutes of background-tab idleness before the WKWebView is freed
    /// to reclaim memory. Tab metadata, favicon, and the Smart Read card
    /// survive; selecting the tab reloads the page. Set to zero to
    /// disable hibernation entirely.
    static let tabHibernationMinutes = "tabs.hibernationMinutes"
    static let bookmarkBarVisible = "bookmarks.barVisible"
    static let bookmarksAutoTagEnabled = "bookmarks.autoTagEnabled"
    static let bookmarksTaggingModel = "bookmarks.taggingModel"
    static let bookmarksAutoTagMigrationCompletedV1 = "bookmarks.autoTagMigrationCompleted_v1"
    static let addBookmarkShortcut = "shortcut.addBookmark"
    static let toggleBookmarkBarShortcut = "shortcut.toggleBookmarkBar"
    static let openBookmarksPaneShortcut = "shortcut.openBookmarksPane"
    static let toolbarShowBookmarkStar = "toolbar.showBookmarkStar"
    static let toolbarShowBookmarksToggle = "toolbar.showBookmarksToggle"
}

/// Modifier choices for Hover Preview. Raw values are stored in
/// `UserDefaults` so the value survives across upgrades; the displayed glyph
/// (⌘ / ⌥ / ⇧) is derived in the UI.
enum HoverPreviewModifier: String, CaseIterable, Identifiable, Sendable {
    case command
    case option
    case shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command: "⌘ Command"
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        }
    }

    var glyph: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .shift: "⇧"
        }
    }

    /// Property name on a DOM `MouseEvent` / `KeyboardEvent` that's `true` when
    /// this modifier is held — used by the link-hover JS to test modifier
    /// state without a Swift round-trip.
    var domEventProperty: String {
        switch self {
        case .command: "metaKey"
        case .option: "altKey"
        case .shift: "shiftKey"
        }
    }

    /// Lowercased `event.key` values that correspond to this modifier on
    /// keyboard events. Mac sends "Meta" for both Command keys.
    var domKeyNames: [String] {
        switch self {
        case .command: ["meta"]
        case .option: ["alt"]
        case .shift: ["shift"]
        }
    }
}

enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.aiProvider: AIProviderKind.codex.rawValue,
            PreferenceKey.aiWorkspacePath: defaultWorkspacePath(),
            PreferenceKey.aiModel: "",
            PreferenceKey.aiSystemPrompt: defaultAISystemPrompt,
            PreferenceKey.aiTools: "",
            PreferenceKey.aiAllowedTools: "",
            PreferenceKey.aiDisallowedTools: "",
            PreferenceKey.aiMCPConfigPath: "",
            PreferenceKey.aiExtraArguments: "",
            PreferenceKey.aiFavoriteModels: "claude:claude-opus-4-7,claude:claude-sonnet-4-6",
            PreferenceKey.aiShowToolChain: true,
            PreferenceKey.codexCLIPath: defaultCodexCLIPath(),
            PreferenceKey.codexWorkspacePath: defaultWorkspacePath(),
            PreferenceKey.codexModel: "",
            PreferenceKey.codexSandbox: "read-only",
            PreferenceKey.claudeCLIPath: defaultClaudeCLIPath(),
            PreferenceKey.searchEngine: SearchEngine.defaultValue.rawValue,
            PreferenceKey.migrationPromptCompleted: false,
            PreferenceKey.toggleChatShortcut: "command+j",
            PreferenceKey.toggleTabsShortcut: "command+b",
            PreferenceKey.newTabShortcut: "command+t",
            PreferenceKey.closeTabShortcut: "command+w",
            PreferenceKey.focusAddressShortcut: "command+l",
            // Multi-modifier defaults are written in canonical order
            // (control + option + shift + command + key) so they match
            // ``AppShortcut.storageValue(from:)``. The keyboard host
            // normalizes incoming bindings as a safety net for any older
            // string that survived in `@AppStorage`.
            PreferenceKey.smartReadShortcut: "shift+command+r",
            PreferenceKey.readerModeShortcut: "command+r",
            PreferenceKey.pasteWithCitationShortcut: "shift+command+v",
            PreferenceKey.googleOAuthClientID: "",
            PreferenceKey.discordOAuthClientID: "",
            PreferenceKey.openDiscordShortcut: "command+d",
            PreferenceKey.clipboardEnabled: true,
            PreferenceKey.clipboardSmartPasteEnabled: true,
            PreferenceKey.clipboardMarkdownStyle: CitedMarkdownStyle.blockquote.rawValue,
            PreferenceKey.clipboardCitationStyle: CitedCitationStyle.bracketed.rawValue,
            PreferenceKey.clipboardBlocklist: CitedClipboardPolicy.defaultBlocklistString,
            PreferenceKey.clipboardAppOverrides: "",
            PreferenceKey.notificationCorner: NotificationCorner.topRight.rawValue,
            PreferenceKey.notificationsWelcomeShown: false,
            PreferenceKey.hoverPreviewEnabled: true,
            PreferenceKey.hoverPreviewModifier: HoverPreviewModifier.command.rawValue,
            PreferenceKey.hoverPreviewDelayMs: 200,
            PreferenceKey.hoverPreviewPrefetchDelayMs: 800,
            PreferenceKey.hoverPreviewPrefetchBlocklist: "",
            PreferenceKey.toolbarShowBack: true,
            PreferenceKey.toolbarShowForward: true,
            PreferenceKey.toolbarShowReload: true,
            PreferenceKey.toolbarShowReaderMode: false,
            PreferenceKey.toolbarShowSmartRead: false,
            PreferenceKey.toolbarShowClipboard: false,
            PreferenceKey.toolbarShowTabRailToggle: true,
            PreferenceKey.toolbarShowChatToggle: true,
            PreferenceKey.tabHibernationMinutes: 30,
            PreferenceKey.bookmarkBarVisible: false,
            PreferenceKey.bookmarksAutoTagEnabled: true,
            PreferenceKey.bookmarksTaggingModel: "",
            PreferenceKey.bookmarksAutoTagMigrationCompletedV1: false,
            PreferenceKey.addBookmarkShortcut: "option+command+d",
            PreferenceKey.toggleBookmarkBarShortcut: "shift+command+b",
            PreferenceKey.openBookmarksPaneShortcut: "option+command+b",
            PreferenceKey.toolbarShowBookmarkStar: true,
            PreferenceKey.toolbarShowBookmarksToggle: true
        ])
    }

    static func defaultCodexCLIPath() -> String {
        let candidatePaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]

        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return candidatePaths[0]
    }

    static func defaultClaudeCLIPath() -> String {
        let candidatePaths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]

        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return candidatePaths[0]
    }

    static func defaultWorkspacePath() -> String {
        let currentDirectory = FileManager.default.currentDirectoryPath
        let gitDirectory = URL(fileURLWithPath: currentDirectory).appendingPathComponent(".git").path

        if FileManager.default.fileExists(atPath: gitDirectory) {
            return currentDirectory
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static let defaultAISystemPrompt = """
    You are The Browser's native AI assistant.

    Be honest about your actual capabilities in this chat. You receive only the information the app includes in the user message, such as the current tab title, URL, conversation history, and native tool results.

    The app may offer native browser tools in the user prompt. Treat only those listed tools as available. If asked what tools or actions you can use, answer narrowly: text responses, current-tab title/URL context, and the listed native browser tools. Do not invent extra feature lists.

    Never claim a browser action happened until a native tool result says it succeeded. Do not write status theatrics like "[Opening ...]" unless an action actually happened outside the model. If the user asks for an unavailable browser action, briefly say you can't do that yet and offer the most useful text-only alternative.

    Stay concise, useful, and practical.
    Avoid emojis in your responses unless they are absolutely necessary for the task.
    """
}
