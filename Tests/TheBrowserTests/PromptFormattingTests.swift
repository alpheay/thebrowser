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

        #expect(prompt == """
        Current tab:
        Title: Page
        URL: https://x

        User request:
        do thing
        """)
    }
}
