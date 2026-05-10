import Foundation

enum PreferenceKey {
    static let codexCLIPath = "codex.cliPath"
    static let codexWorkspacePath = "codex.workspacePath"
    static let codexModel = "codex.model"
    static let codexSandbox = "codex.sandbox"
    static let toggleChatShortcut = "shortcut.toggleChat"
    static let toggleTabsShortcut = "shortcut.toggleTabs"
    static let newTabShortcut = "shortcut.newTab"
    static let closeTabShortcut = "shortcut.closeTab"
    static let focusAddressShortcut = "shortcut.focusAddress"
}

enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.codexCLIPath: defaultCodexCLIPath(),
            PreferenceKey.codexWorkspacePath: defaultCodexWorkspacePath(),
            PreferenceKey.codexModel: "",
            PreferenceKey.codexSandbox: "read-only",
            PreferenceKey.toggleChatShortcut: "command+j",
            PreferenceKey.toggleTabsShortcut: "command+b",
            PreferenceKey.newTabShortcut: "command+t",
            PreferenceKey.closeTabShortcut: "command+w",
            PreferenceKey.focusAddressShortcut: "command+l"
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

    static func defaultCodexWorkspacePath() -> String {
        let currentDirectory = FileManager.default.currentDirectoryPath
        let gitDirectory = URL(fileURLWithPath: currentDirectory).appendingPathComponent(".git").path

        if FileManager.default.fileExists(atPath: gitDirectory) {
            return currentDirectory
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
