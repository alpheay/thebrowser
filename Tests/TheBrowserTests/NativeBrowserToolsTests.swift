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

    @Test("Parses a trailing tool call that follows leading prose on a new line")
    func parsesTrailingToolCallAfterProse() throws {
        let response = """
        That looks like it might be "GT Canvas" (Georgia Tech Canvas). Let me open that for you.
        {"tool":"open","url":"https://canvas.gatech.edu"}
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://canvas.gatech.edu")
    }

    @Test("Parses a trailing tool call when prose contains brace-like text")
    func parsesTrailingToolCallWithBracesInProse() throws {
        let response = """
        Some folks write sets like {a, b, c} — anyway, opening that now.
        {"tool":"open","url":"https://example.com"}
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://example.com")
    }

    @Test("Picks the trailing tool call when a JSON example also appears mid-prose")
    func prefersTrailingToolCallOverEmbeddedExample() throws {
        let response = #"""
        You can call it like {"tool":"open","url":"https://example.com"} — here goes:
        {"tool":"open","url":"https://canvas.gatech.edu"}
        """#

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://canvas.gatech.edu")
    }

    @Test("Ignores a JSON object that is not the last non-whitespace content")
    func ignoresJSONFollowedByMoreProse() {
        let response = #"{"tool":"open","url":"https://example.com"} — let me know if that's right."#

        #expect(NativeBrowserToolCall.parse(from: response) == nil)
    }

    @MainActor
    @Test("Open tool navigates through the injected browser action")
    func openToolInvokesNavigation() async {
        var openedURL: URL?
        let executor = NativeBrowserToolExecutor(
            openURL: { url in openedURL = url },
            readTabsContent: { _ in "" },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )
        let result = await executor.execute(
            NativeBrowserToolCall(name: .open, url: "youtube.com")
        )

        #expect(result.succeeded)
        #expect(openedURL?.absoluteString == "https://youtube.com")
    }

    @Test("Continuation prompt includes tool results and asks for normal answer")
    func continuationPromptIncludesToolResult() {
        let result = NativeBrowserToolResult(
            call: NativeBrowserToolCall(name: .open, url: "https://example.com"),
            succeeded: true,
            content: "Opened https://example.com in the current tab."
        )

        let prompt = NativeBrowserToolPrompt.continuationPrompt(basePrompt: "Base prompt", results: [result])

        #expect(prompt.contains("Base prompt"))
        #expect(prompt.contains("Tool: open"))
        #expect(prompt.contains("Status: success"))
        #expect(prompt.contains("answer normally and briefly"))
    }

    @Test("read_tabs parses with no arguments")
    func readTabsNoArgs() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"read_tabs"}"#))
        #expect(call.name == .readTabs)
        #expect(call.indices == nil)
        #expect(call.rawInput == "all")
    }

    @Test("read_tabs parses with explicit indices array")
    func readTabsIndices() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"read_tabs","indices":[1,3]}"#))
        #expect(call.name == .readTabs)
        #expect(call.indices == [1, 3])
        #expect(call.rawInput == "1,3")
    }

    @Test("create_artifact requires html, surfaces title in rawInput")
    func createArtifactParses() throws {
        let json = #"{"tool":"create_artifact","title":"Market Brief","html":"<!doctype html><body>hi</body>"}"#
        let call = try #require(NativeBrowserToolCall.parse(from: json))
        #expect(call.name == .createArtifact)
        #expect(call.title == "Market Brief")
        #expect(call.html?.contains("<body>hi</body>") == true)
        #expect(call.rawInput == "Market Brief")
    }

    @Test("create_artifact missing html is rejected")
    func createArtifactMissingHTML() {
        let json = #"{"tool":"create_artifact","title":"Empty"}"#
        #expect(NativeBrowserToolCall.parse(from: json) == nil)
    }

    @Test("ArtifactStore slugs titles for safe filenames")
    func artifactSlug() {
        #expect(ArtifactStore.slug(from: "Market Overview!") == "market-overview")
        #expect(ArtifactStore.slug(from: "  hello   world  ") == "hello-world")
        #expect(ArtifactStore.slug(from: "***") == "artifact")
        #expect(ArtifactStore.slug(from: "") == "artifact")
        let long = String(repeating: "a", count: 200)
        #expect(ArtifactStore.slug(from: long).count <= 60)
    }
}
