import Foundation
import Testing
@testable import TheBrowser

@Suite("Native browser tools")
struct NativeBrowserToolsTests {
    @Test("Parses flat tool call JSON")
    func parsesFlatToolCall() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"open","url":"https://youtube.com"}"#))

        #expect(call.name == .open)
        #expect(call.url == "https://youtube.com")
    }

    @Test("Parses harness-style name plus arguments JSON inside a fence")
    func parsesArgumentsToolCall() throws {
        let response = """
        ```browser_tool
        {"name":"search","arguments":{"query":"best ramen brooklyn"}}
        ```
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .search)
        #expect(call.query == "best ramen brooklyn")
    }

    @Test("Ignores normal assistant prose")
    func ignoresNormalProse() {
        #expect(NativeBrowserToolCall.parse(from: "I can help with that.") == nil)
    }

    @Test("Ignores JSON examples embedded in prose")
    func ignoresEmbeddedJSONExamples() {
        let response = #"I can use open like {"tool":"open","url":"https://example.com"} when needed."#

        #expect(NativeBrowserToolCall.parse(from: response) == nil)
    }

    @MainActor
    @Test("Open tool navigates through the injected browser action")
    func openToolInvokesNavigation() async {
        var openedURL: URL?
        let executor = NativeBrowserToolExecutor { url in
            openedURL = url
        }
        let result = await executor.execute(
            NativeBrowserToolCall(name: .open, url: "youtube.com", query: nil)
        )

        #expect(result.succeeded)
        #expect(openedURL?.absoluteString == "https://youtube.com")
    }

    @Test("Continuation prompt includes tool results and asks for normal answer")
    func continuationPromptIncludesToolResult() {
        let result = NativeBrowserToolResult(
            call: NativeBrowserToolCall(name: .open, url: "https://example.com", query: nil),
            succeeded: true,
            content: "Opened https://example.com in the current tab."
        )

        let prompt = NativeBrowserToolPrompt.continuationPrompt(basePrompt: "Base prompt", results: [result])

        #expect(prompt.contains("Base prompt"))
        #expect(prompt.contains("Tool: open"))
        #expect(prompt.contains("Status: success"))
        #expect(prompt.contains("answer normally and briefly"))
    }
}
