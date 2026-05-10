import Foundation
import Testing
@testable import TheBrowser

@Suite("Replacement system prompt")
struct EffectiveSystemPromptTests {
    @Test("Effective system prompt is exactly the user's prompt after trim",
          arguments: AIProviderKind.allCases)
    func effectivePromptIsOnlyUserPrompt(provider: AIProviderKind) {
        let config = TestSupport.makeConfiguration(
            provider: provider,
            model: provider == .claude ? "claude-opus-4-7" : "gpt-5.5",
            systemPrompt: "  Be terse.\nStay practical.  "
        )

        #expect(CLIArguments.effectiveSystemPrompt(for: config) == "Be terse.\nStay practical.")
    }

    @Test("Blank user prompt stays blank instead of falling back to provider identity")
    func blankPromptStaysBlank() {
        let claude = TestSupport.makeConfiguration(provider: .claude, model: "claude-sonnet-4-6", systemPrompt: "  \n\t ")
        let codex = TestSupport.makeConfiguration(provider: .codex, model: "gpt-5.5", systemPrompt: "")

        #expect(CLIArguments.effectiveSystemPrompt(for: claude) == "")
        #expect(CLIArguments.effectiveSystemPrompt(for: codex) == "")
    }

    @Test("Effective prompt contains no harness identity, model, or tool banner")
    func promptHasNoHarnessLeakage() {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            model: "claude-sonnet-4-6",
            systemPrompt: "You are The Browser's native AI assistant."
        )

        let prompt = CLIArguments.effectiveSystemPrompt(for: config)

        #expect(!prompt.contains("Claude"))
        #expect(!prompt.contains("Codex"))
        #expect(!prompt.localizedCaseInsensitiveContains("tool"))
        #expect(!prompt.localizedCaseInsensitiveContains("model id"))
        #expect(!prompt.localizedCaseInsensitiveContains("running as"))
    }
}
