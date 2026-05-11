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
    static let googleOAuthClientID = "google.oauth.clientID"
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
            PreferenceKey.smartReadShortcut: "command+shift+r",
            PreferenceKey.readerModeShortcut: "command+r",
            PreferenceKey.googleOAuthClientID: ""
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
