import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("ChatSessionStore.clearAll")
struct ChatSessionStoreTests {
    private static func makeIsolatedStore() -> (ChatSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ChatSessionStore(root: root), root)
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("clearAll removes every session directory under the root")
    func clearAllRemovesSessionDirectories() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        store.directory(for: "alpha")
        store.directory(for: "beta")
        store.directory(for: "gamma")

        let beforeContents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(beforeContents?.count == 3)

        store.clearAll()

        let afterContents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(afterContents?.isEmpty == true)
    }

    @Test("clearAll deletes saved messages.json files inside each session")
    func clearAllRemovesSavedMessages() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        let context = BrowserPageContext(title: "T", url: "u")
        store.save(messages: [ChatMessage(role: .user, text: "hi")], sessionID: "alpha", pageContext: context)
        store.save(messages: [ChatMessage(role: .user, text: "yo")], sessionID: "beta", pageContext: context)

        let alphaFile = root.appendingPathComponent("alpha/messages.json")
        let betaFile = root.appendingPathComponent("beta/messages.json")
        #expect(FileManager.default.fileExists(atPath: alphaFile.path))
        #expect(FileManager.default.fileExists(atPath: betaFile.path))

        store.clearAll()

        #expect(!FileManager.default.fileExists(atPath: alphaFile.path))
        #expect(!FileManager.default.fileExists(atPath: betaFile.path))
    }

    @Test("clearAll preserves the root directory so subsequent saves keep working")
    func clearAllPreservesRoot() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        store.directory(for: "alpha")
        store.clearAll()

        #expect(FileManager.default.fileExists(atPath: root.path))

        let context = BrowserPageContext(title: "T", url: "u")
        store.save(messages: [ChatMessage(role: .user, text: "after-clear")], sessionID: "delta", pageContext: context)
        let deltaFile = root.appendingPathComponent("delta/messages.json")
        #expect(FileManager.default.fileExists(atPath: deltaFile.path))
    }

    @Test("save and load round-trips the assistant tool chain")
    func toolChainRoundTrips() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        let artifactURL = URL(fileURLWithPath: "/tmp/2026-05-10_12-00-00_market-brief.html")
        let chain = [
            ChatMessage.ToolInvocation(tool: "open", input: "https://youtube.com", succeeded: true),
            ChatMessage.ToolInvocation(tool: "search", input: "best ramen brooklyn", succeeded: false),
            ChatMessage.ToolInvocation(
                tool: "create_artifact",
                input: "Market Brief",
                succeeded: true,
                artifactURL: artifactURL
            )
        ]
        let assistant = ChatMessage(role: .assistant, text: "Done.", toolChain: chain)
        let context = BrowserPageContext(title: "T", url: "u")
        store.save(messages: [ChatMessage(role: .user, text: "hi"), assistant], sessionID: "chain", pageContext: context)

        let reloaded = store.load(sessionID: "chain")
        #expect(reloaded.count == 2)
        #expect(reloaded[0].toolChain.isEmpty)
        #expect(reloaded[1].toolChain == chain)
        #expect(reloaded[1].toolChain.last?.artifactURL == artifactURL)
    }

    @Test("save and load round-trips status + output for the assistant tool chain")
    func toolChainStatusRoundTrips() {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        let runningInvocation = ChatMessage.ToolInvocation(
            tool: "search",
            input: "ramen brooklyn",
            status: .running
        )
        let completedInvocation = ChatMessage.ToolInvocation(
            tool: "fetch",
            input: "https://example.com",
            status: .completed,
            output: "Hello world."
        )
        let failedInvocation = ChatMessage.ToolInvocation(
            tool: "open",
            input: "::bad-url::",
            status: .failed,
            output: "Invalid URL."
        )

        let assistant = ChatMessage(
            role: .assistant,
            text: "Done.",
            toolChain: [runningInvocation, completedInvocation, failedInvocation]
        )
        let context = BrowserPageContext(title: "T", url: "u")
        store.save(messages: [assistant], sessionID: "status", pageContext: context)

        let reloaded = store.load(sessionID: "status")
        #expect(reloaded.count == 1)
        let chain = reloaded[0].toolChain
        #expect(chain.count == 3)
        // Identity round-trips so the UI can keep stable @ForEach IDs
        // even after a reload.
        #expect(chain[0].id == runningInvocation.id)
        #expect(chain[0].status == .running)
        #expect(chain[1].status == .completed)
        #expect(chain[1].output == "Hello world.")
        #expect(chain[2].status == .failed)
        #expect(chain[2].output == "Invalid URL.")
    }

    @Test("Legacy payloads with only `succeeded` map to completed / failed status")
    func legacyStatusInference() throws {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        // Pre-status payload: only `succeeded` and no `status` field.
        let legacyJSON = """
        {
          "id" : "legacy-status",
          "messages" : [
            {
              "role" : "assistant",
              "text" : "Two old tools.",
              "toolChain" : [
                { "tool" : "open", "input" : "https://a.com", "succeeded" : true },
                { "tool" : "search", "input" : "q", "succeeded" : false }
              ]
            }
          ],
          "pageTitle" : "T",
          "pageURL" : "u",
          "updatedAt" : "2026-05-10T12:00:00Z"
        }
        """
        let dir = root.appendingPathComponent("legacy-status", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("messages.json"))

        let reloaded = store.load(sessionID: "legacy-status")
        #expect(reloaded.count == 1)
        let chain = reloaded[0].toolChain
        #expect(chain.count == 2)
        #expect(chain[0].status == .completed)
        #expect(chain[1].status == .failed)
    }

    @Test("Sessions saved before artifactURL existed still load (field is optional)")
    func legacyToolChainPayloadDecodes() throws {
        let (store, root) = Self.makeIsolatedStore()
        defer { Self.cleanup(root) }

        // Hand-rolled payload mirroring the pre-artifactURL on-disk format:
        // toolChain entries lack the new key entirely.
        let legacyJSON = """
        {
          "id" : "legacy",
          "messages" : [
            {
              "role" : "assistant",
              "text" : "Done.",
              "toolChain" : [
                { "tool" : "create_artifact", "input" : "Market Brief", "succeeded" : true }
              ]
            }
          ],
          "pageTitle" : "T",
          "pageURL" : "u",
          "updatedAt" : "2026-05-10T12:00:00Z"
        }
        """
        let dir = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("messages.json"))

        let reloaded = store.load(sessionID: "legacy")
        #expect(reloaded.count == 1)
        #expect(reloaded[0].toolChain.count == 1)
        #expect(reloaded[0].toolChain[0].tool == "create_artifact")
        #expect(reloaded[0].toolChain[0].artifactURL == nil)
    }

    @Test("clearAll is a no-op when the root does not yet exist")
    func clearAllWithoutRootDoesNothing() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatSessionStore(root: missingRoot)

        // Should neither throw nor create the directory.
        store.clearAll()

        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }
}
