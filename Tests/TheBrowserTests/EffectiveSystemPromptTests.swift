import Foundation
import Testing
@testable import TheBrowser

@Suite("Effective system prompt and identity line")
struct EffectiveSystemPromptTests {
    @Test("Identity line uses the model's display name when known")
    func identityWithKnownModel() {
        let line = CLIArguments.identityLine(provider: .claude, model: "claude-opus-4-7")

        #expect(line.contains("Claude Opus 4.7"))
        #expect(line.contains("Claude"))
        #expect(line.contains("claude-opus-4-7"))
    }

    @Test("Identity line falls back to the raw model id when the model is unknown")
    func identityWithUnknownModel() {
        let line = CLIArguments.identityLine(provider: .claude, model: "claude-mystery-99")

        #expect(line.contains("claude-mystery-99"))
        #expect(line.contains("Claude"))
    }

    @Test("Identity line whitespace-trims the model id before display and lookup")
    func identityTrimsModel() {
        let line = CLIArguments.identityLine(provider: .codex, model: "  gpt-5.5  ")

        #expect(line.contains("GPT-5.5"))
        #expect(line.contains("gpt-5.5"))
        #expect(!line.contains("  gpt-5.5  "))
    }

    @Test("Identity line for an empty model names only the provider")
    func identityWithoutModel() {
        let claude = CLIArguments.identityLine(provider: .claude, model: "")
        let codex = CLIArguments.identityLine(provider: .codex, model: "   ")

        #expect(claude.contains("Claude"))
        #expect(claude.lowercased().contains("default"))
        #expect(codex.contains("Codex"))
        #expect(codex.lowercased().contains("default"))
    }

    @Test("Effective system prompt joins the user's prompt with the identity line, separated by a blank line")
    func combinesUserPromptAndIdentity() {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            model: "claude-opus-4-7",
            systemPrompt: "Be terse."
        )

        let combined = CLIArguments.effectiveSystemPrompt(for: config)

        #expect(combined.hasPrefix("Be terse."))
        #expect(combined.contains("\n\n"))
        #expect(combined.contains("Claude Opus 4.7"))
    }

    @Test("Effective system prompt trims surrounding whitespace from the user's prompt")
    func trimsUserPrompt() {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            model: "claude-opus-4-7",
            systemPrompt: "   Be terse.\n\n  "
        )

        let combined = CLIArguments.effectiveSystemPrompt(for: config)

        #expect(combined.hasPrefix("Be terse."))
        #expect(!combined.hasPrefix(" "))
    }

    @Test("Effective system prompt is just the identity line when the user prompt is blank")
    func identityOnlyWhenBlank() {
        let blank = TestSupport.makeConfiguration(
            provider: .codex,
            model: "gpt-5.5",
            systemPrompt: "   \n  "
        )

        let combined = CLIArguments.effectiveSystemPrompt(for: blank)

        #expect(combined == CLIArguments.identityLine(provider: .codex, model: "gpt-5.5"))
    }
}
