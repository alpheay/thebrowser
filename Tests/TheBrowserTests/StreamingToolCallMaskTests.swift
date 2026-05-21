import Foundation
import Testing
@testable import TheBrowser

@Suite("Streaming tool-call mask")
struct StreamingToolCallMaskTests {
    @Test("Empty input passes through")
    func emptyPassesThrough() {
        #expect(StreamingToolCallMask.visiblePrefix(in: "") == "")
    }

    @Test("Pure prose with no JSON is preserved exactly")
    func proseWithoutJSON() {
        let prose = "Here's a quick summary of the article."
        #expect(StreamingToolCallMask.visiblePrefix(in: prose) == prose)
    }

    @Test("Inline JSON mid-prose stays visible (it's not a tool call)")
    func inlineJSONStaysVisible() {
        let text = "You can write sets like {a, b, c} in math."
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == text)
    }

    @Test("Entire buffer is an in-progress JSON object → fully hidden")
    func entireBufferIsInProgressJSON() {
        let text = #"{"tool":"open","ur"#
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "")
    }

    @Test("Entire buffer is a completed JSON object → fully hidden")
    func entireBufferIsCompletedJSON() {
        let text = #"{"tool":"open","url":"https://example.com"}"#
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "")
    }

    @Test("Prose followed by a newline + in-progress JSON keeps the prose")
    func proseThenInProgressJSON() {
        let text = "Looking up your inbox now.\n{\"tool\":\"mail_sear"
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "Looking up your inbox now.")
    }

    @Test("Prose followed by a newline + completed JSON keeps the prose")
    func proseThenCompletedJSON() {
        let text = "Opening that for you.\n{\"tool\":\"open\",\"url\":\"https://example.com\"}"
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "Opening that for you.")
    }

    @Test("Multi-line JSON object at end is hidden in full")
    func multiLineTrailingJSONHidden() {
        let text = """
        Now checking the inbox.
        {
          "tool": "mail_search",
          "mailbox": "inbox"
        }
        """
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "Now checking the inbox.")
    }

    @Test("Multi-line in-progress JSON with unclosed string is hidden")
    func multiLineInProgressJSONHidden() {
        let text = """
        Looking that up.
        {
          "tool": "mail_search",
          "mailbox": "inb
        """
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "Looking that up.")
    }

    @Test("Embedded JSON followed by more prose stays visible in full")
    func embeddedJSONWithTrailingProseStaysVisible() {
        let text = "Use {curly braces} like this — done."
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == text)
    }

    @Test("JSON object on its own line with trailing prose stays visible")
    func jsonOnOwnLineFollowedByProseStaysVisible() {
        // This is the embedded-example case: a self-contained JSON
        // block, followed by more prose. Not a tool call (something
        // sits after the close brace).
        let text = """
        Example:
        {"tool":"open"}
        And another sentence after.
        """
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == text)
    }

    @Test("Braces inside JSON string literals don't confuse the mask")
    func bracesInStringsAreNotCounted() {
        // The string value contains `}`. The mask must treat it as
        // part of the string, not as a JSON close.
        let text = #"Searching now.\n{"tool":"search","query":"value with } brace"}"#
            .replacingOccurrences(of: "\\n", with: "\n")
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "Searching now.")
    }

    @Test("Leading whitespace before a JSON-only buffer still hides everything")
    func leadingWhitespaceBeforeJSONHidden() {
        let text = "  \n  {\"tool\":\"open\"}"
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == "")
    }

    @Test("Malformed JSON (extra close brace) gracefully returns input as-is")
    func malformedJSONFallsThrough() {
        let text = "Some prose with too many }} braces."
        #expect(StreamingToolCallMask.visiblePrefix(in: text) == text)
    }
}
