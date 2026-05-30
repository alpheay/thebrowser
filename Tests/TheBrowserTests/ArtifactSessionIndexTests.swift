import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("ChatSessionStore.artifactSessionIndex")
struct ArtifactSessionIndexTests {
    private static func makeIsolatedStore() -> (ChatSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ChatSessionStore(root: root), root)
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("maps an artifact file name to the session that produced it")
    func mapsArtifactToSession() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        let artifactURL = URL(fileURLWithPath:
            "/Users/x/.thebrowser/web_artifacts/2026-05-10_12-00-00_market-brief.html")
        let chain = [
            ChatMessage.ToolInvocation(
                tool: "create_artifact",
                input: "Market Brief",
                succeeded: true,
                artifactURL: artifactURL
            )
        ]
        let assistant = ChatMessage(role: .assistant, text: "Done.", toolChain: chain)
        let context = BrowserPageContext(title: "Markets", url: "https://example.com")
        store.save(
            messages: [ChatMessage(role: .user, text: "make a brief"), assistant],
            sessionID: "alpha",
            pageContext: context
        )

        let ref = store.artifactSessionIndex()["2026-05-10_12-00-00_market-brief.html"]
        #expect(ref?.sessionID == "alpha")
        #expect(ref?.pageTitle == "Markets")
        #expect(ref?.firstUserMessage == "make a brief")
    }

    @Test("sessions without artifacts contribute no entries")
    func ignoresSessionsWithoutArtifacts() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        let context = BrowserPageContext(title: "T", url: "u")
        store.save(
            messages: [ChatMessage(role: .user, text: "hi")],
            sessionID: "beta",
            pageContext: context
        )

        #expect(store.artifactSessionIndex().isEmpty)
    }

    @Test("when two sessions reference the same artifact, the newest wins")
    func newestSessionWins() throws {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        func writeSession(id: String, updatedAt: String) throws {
            let json = """
            {
              "id" : "\(id)",
              "messages" : [
                { "role" : "user", "text" : "from \(id)" },
                {
                  "role" : "assistant",
                  "text" : "ok",
                  "toolChain" : [
                    {
                      "tool" : "create_artifact",
                      "input" : "Brief",
                      "succeeded" : true,
                      "artifactURL" : "file:///w/2026-05-10_12-00-00_brief.html"
                    }
                  ]
                }
              ],
              "pageTitle" : "\(id)-page",
              "pageURL" : "u",
              "updatedAt" : "\(updatedAt)"
            }
            """
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("messages.json"))
        }

        try writeSession(id: "older", updatedAt: "2026-05-10T12:00:00Z")
        try writeSession(id: "newer", updatedAt: "2026-05-12T09:30:00Z")

        let ref = store.artifactSessionIndex()["2026-05-10_12-00-00_brief.html"]
        #expect(ref?.sessionID == "newer")
        #expect(ref?.pageTitle == "newer-page")
    }
}
