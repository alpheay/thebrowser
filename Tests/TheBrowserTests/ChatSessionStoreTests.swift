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
