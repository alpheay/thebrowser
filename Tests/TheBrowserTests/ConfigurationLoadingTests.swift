import Foundation
import Testing
@testable import TheBrowser

@Suite("AIHarnessConfiguration.current loads from UserDefaults")
struct ConfigurationLoadingTests {
    private static func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "TheBrowserTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    private static func cleanup(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test("Missing aiProvider key defaults to codex")
    func defaultsToCodex() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }

        let config = AIHarnessConfiguration.current(defaults: defaults)

        #expect(config.provider == .codex)
    }

    @Test("aiProvider=claude routes to the Claude CLI path")
    func claudeProviderUsesClaudePath() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("claude", forKey: PreferenceKey.aiProvider)
        defaults.set("/custom/claude", forKey: PreferenceKey.claudeCLIPath)
        defaults.set("/custom/codex", forKey: PreferenceKey.codexCLIPath)

        let config = AIHarnessConfiguration.current(defaults: defaults)

        #expect(config.provider == .claude)
        #expect(config.cliPath == "/custom/claude")
    }

    @Test("aiProvider=codex routes to the Codex CLI path")
    func codexProviderUsesCodexPath() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("codex", forKey: PreferenceKey.aiProvider)
        defaults.set("/custom/claude", forKey: PreferenceKey.claudeCLIPath)
        defaults.set("/custom/codex", forKey: PreferenceKey.codexCLIPath)

        let config = AIHarnessConfiguration.current(defaults: defaults)

        #expect(config.provider == .codex)
        #expect(config.cliPath == "/custom/codex")
    }

    @Test("Unknown provider value falls back to codex")
    func unknownProviderFallsBackToCodex() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("gemini", forKey: PreferenceKey.aiProvider)

        #expect(AIHarnessConfiguration.current(defaults: defaults).provider == .codex)
    }

    @Test("aiWorkspacePath wins over codexWorkspacePath fallback")
    func workspacePathPrecedence() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("/from/ai", forKey: PreferenceKey.aiWorkspacePath)
        defaults.set("/from/codex", forKey: PreferenceKey.codexWorkspacePath)

        #expect(AIHarnessConfiguration.current(defaults: defaults).workspacePath == "/from/ai")
    }

    @Test("codexWorkspacePath is used when aiWorkspacePath is absent")
    func workspacePathFallback() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("/from/codex", forKey: PreferenceKey.codexWorkspacePath)

        #expect(AIHarnessConfiguration.current(defaults: defaults).workspacePath == "/from/codex")
    }

    @Test("aiModel wins over codexModel fallback")
    func modelPrecedence() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("model-a", forKey: PreferenceKey.aiModel)
        defaults.set("model-c", forKey: PreferenceKey.codexModel)

        #expect(AIHarnessConfiguration.current(defaults: defaults).model == "model-a")
    }

    @Test("codexModel is used when aiModel is absent")
    func modelFallback() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("model-c", forKey: PreferenceKey.codexModel)

        #expect(AIHarnessConfiguration.current(defaults: defaults).model == "model-c")
    }

    @Test("Missing model defaults to empty string")
    func modelDefaultsToEmpty() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }

        #expect(AIHarnessConfiguration.current(defaults: defaults).model == "")
    }

    @Test("Missing aiSystemPrompt falls back to AppDefaults.defaultAISystemPrompt")
    func systemPromptDefaultsToAppDefault() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }

        #expect(AIHarnessConfiguration.current(defaults: defaults).systemPrompt == AppDefaults.defaultAISystemPrompt)
    }

    @Test("Custom aiSystemPrompt is loaded verbatim")
    func systemPromptLoaded() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("custom prompt", forKey: PreferenceKey.aiSystemPrompt)

        #expect(AIHarnessConfiguration.current(defaults: defaults).systemPrompt == "custom prompt")
    }

    @Test("Missing tool/MCP/extras keys default to empty strings")
    func toolKeysDefaultToEmpty() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }

        let config = AIHarnessConfiguration.current(defaults: defaults)

        #expect(config.tools == "")
        #expect(config.allowedTools == "")
        #expect(config.disallowedTools == "")
        #expect(config.mcpConfigPath == "")
        #expect(config.extraArguments == "")
    }

    @Test("Tool/MCP/extras keys are loaded verbatim")
    func toolKeysAreLoaded() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("Read,Edit", forKey: PreferenceKey.aiTools)
        defaults.set("Bash", forKey: PreferenceKey.aiAllowedTools)
        defaults.set("Write", forKey: PreferenceKey.aiDisallowedTools)
        defaults.set("/tmp/mcp.json", forKey: PreferenceKey.aiMCPConfigPath)
        defaults.set("--verbose\n--foo", forKey: PreferenceKey.aiExtraArguments)

        let config = AIHarnessConfiguration.current(defaults: defaults)

        #expect(config.tools == "Read,Edit")
        #expect(config.allowedTools == "Bash")
        #expect(config.disallowedTools == "Write")
        #expect(config.mcpConfigPath == "/tmp/mcp.json")
        #expect(config.extraArguments == "--verbose\n--foo")
    }

    @Test("Missing codexSandbox defaults to read-only")
    func sandboxDefaultsToReadOnly() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }

        #expect(AIHarnessConfiguration.current(defaults: defaults).sandbox == "read-only")
    }

    @Test("Custom codexSandbox is loaded verbatim")
    func sandboxLoaded() {
        let (defaults, suite) = Self.makeIsolatedDefaults()
        defer { Self.cleanup(suite) }
        defaults.set("workspace-write", forKey: PreferenceKey.codexSandbox)

        #expect(AIHarnessConfiguration.current(defaults: defaults).sandbox == "workspace-write")
    }
}
