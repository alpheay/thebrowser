import Foundation
import Testing
@testable import TheBrowser

@Suite("Agent status labels")
struct AgentStatusLabelTests {
    @Test("Hostname is extracted from a URL argument")
    func hostExtractedFromURL() {
        let call = NativeBrowserToolCall(
            name: .open,
            url: "https://canvas.gatech.edu/courses/123"
        )
        #expect(AgentStatusLabel.forActiveTool(call) == "Opening canvas.gatech.edu…")
    }

    @Test("Bare hostnames without scheme still get a clean status label")
    func hostExtractedFromSchemelessURL() {
        let call = NativeBrowserToolCall(name: .fetch, url: "example.com/blog")
        #expect(AgentStatusLabel.forActiveTool(call) == "Fetching example.com…")
    }

    @Test("Tool-specific labels surface for each native tool")
    func toolSpecificLabels() {
        let cases: [(NativeBrowserToolName, String)] = [
            (.search, "Searching the web…"),
            (.readTabs, "Reading open tabs…"),
            (.readHighlights, "Reading highlights…"),
            (.readSmartRead, "Reading Smart Read…"),
            (.mailSearch, "Searching mail…"),
            (.mailReadThread, "Reading mail thread…"),
            (.mailShow, "Opening mail…"),
            (.mailDraft, "Drafting reply…"),
            (.mailSend, "Sending mail…"),
            (.mailModify, "Organizing mail…"),
            (.mailTriage, "Triaging inbox…"),
            (.mailMemory, "Updating memory…"),
            (.mailRemind, "Setting reminder…"),
            (.createArtifact, "Saving artifact…"),
            (.webControl, "Controlling page…")
        ]
        for (name, expected) in cases {
            let call = NativeBrowserToolCall(name: name)
            #expect(AgentStatusLabel.forActiveTool(call) == expected, "label for \(name.rawValue)")
        }
    }
}
