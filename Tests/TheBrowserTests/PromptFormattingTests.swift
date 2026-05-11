import Foundation
import Testing
@testable import TheBrowser

@Suite("Prompt formatting from browser context")
struct PromptFormattingTests {
    @Test("Title and URL render under the Current tab heading")
    func includesTitleAndURL() {
        let context = BrowserPageContext(title: "Anthropic", url: "https://anthropic.com")
        let prompt = AIProviderClient.prompt(for: "what's new?", context: context)

        #expect(prompt.contains("Current tab:"))
        #expect(prompt.contains("Title: Anthropic"))
        #expect(prompt.contains("URL: https://anthropic.com"))
    }

    @Test("Empty URL is rendered as Home page")
    func emptyURLBecomesHomePage() {
        let context = BrowserPageContext(title: "Start", url: "")
        let prompt = AIProviderClient.prompt(for: "hello", context: context)

        #expect(prompt.contains("URL: Home page"))
    }

    @Test("User message renders under the User request heading")
    func includesUserMessage() {
        let context = BrowserPageContext(title: "T", url: "u")
        let prompt = AIProviderClient.prompt(for: "summarize this", context: context)

        #expect(prompt.contains("User request:"))
        #expect(prompt.contains("summarize this"))
    }

    @Test("Multi-line user messages are preserved verbatim")
    func multilineMessagePreserved() {
        let message = "line one\nline two\n\nline four"
        let context = BrowserPageContext(title: "T", url: "u")
        let prompt = AIProviderClient.prompt(for: message, context: context)

        #expect(prompt.contains(message))
    }

    @Test("Full prompt has the expected structure")
    func fullStructure() {
        let context = BrowserPageContext(title: "Page", url: "https://x")
        let prompt = AIProviderClient.prompt(for: "do thing", context: context)

        #expect(prompt.contains(NativeBrowserToolPrompt.instructions))
        #expect(prompt.contains("""
        Current tab:
        Title: Page
        URL: https://x
        """))
        #expect(prompt.hasSuffix("""
        User request:
        do thing
        """))
    }

    @Test("Prompt documents native browser tools")
    func includesNativeBrowserToolInstructions() {
        let context = BrowserPageContext(title: "Page", url: "https://x")
        let prompt = AIProviderClient.prompt(for: "open youtube", context: context)

        #expect(prompt.contains(#"{"tool":"open","url":"https://example.com"}"#))
        #expect(prompt.contains(#"{"tool":"search","query":"weather in New York"}"#))
        #expect(prompt.contains(#"{"tool":"fetch","url":"https://example.com/article"}"#))
        #expect(prompt.contains(#"{"tool":"web_control","task":"#))
    }

    @Test("Prompt includes selected provider and model identity when provided")
    func includesRuntimeModelIdentity() {
        let context = BrowserPageContext(title: "Page", url: "https://x")
        let configuration = TestSupport.makeConfiguration(
            provider: .claude,
            model: "claude-sonnet-4-6"
        )
        let prompt = AIProviderClient.prompt(
            for: "what model are you?",
            context: context,
            configuration: configuration
        )

        #expect(prompt.contains("AI runtime:"))
        #expect(prompt.contains("Provider: Claude"))
        #expect(prompt.contains("Model: Claude Sonnet 4.6"))
        #expect(prompt.contains("Model ID: claude-sonnet-4-6"))
        #expect(prompt.contains("If the user asks what model you are"))
    }

    @Test("Prompt is honest when no explicit model is configured")
    func runtimeModelIdentityDoesNotGuessWhenMissing() {
        let context = BrowserPageContext(title: "Page", url: "https://x")
        let configuration = TestSupport.makeConfiguration(provider: .codex, model: "")
        let prompt = AIProviderClient.prompt(
            for: "what model are you?",
            context: context,
            configuration: configuration
        )

        #expect(prompt.contains("Provider: Codex"))
        #expect(prompt.contains("Model: Not explicitly configured"))
        #expect(prompt.contains("Model ID: not explicitly configured"))
    }
}
