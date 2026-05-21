import Foundation
import Testing
@testable import TheBrowser

@Suite("Thread store")
struct ThreadStoreTests {
    @Test("ThreadStore round-trips tabs, agent context, archive, and delete")
    func threadStoreRoundTrip() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ThreadStore(inMemory: true, scratchRoot: root)
        let agentContext = ThreadAgentContext(sessionID: "session-a").serialized
        let firstTab = TabSnapshot(
            url: URL(string: "https://example.com/a"),
            title: "Example A",
            interactionState: Data([1, 2, 3]),
            lastScreenshotPath: "/tmp/example-a.png",
            lastVisitedAt: Date(timeIntervalSince1970: 100)
        )

        let created = try await store.create(
            tabs: [firstTab],
            agentContext: agentContext,
            isWindowOpen: true
        )

        #expect(created.title == "Example A")
        #expect(created.agentContext == agentContext)
        #expect(created.scratchDirPath.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: created.scratchDirPath))

        let listed = try await store.list()
        #expect(listed.map(\.id) == [created.id])

        let updatedTab = TabSnapshot(
            id: firstTab.id,
            url: URL(string: "https://example.com/b"),
            title: "Example B",
            interactionState: Data([4, 5, 6]),
            lastScreenshotPath: "/tmp/example-b.png",
            lastVisitedAt: Date(timeIntervalSince1970: 200)
        )
        let updated = try await store.updateTabs(id: created.id, tabs: [updatedTab])

        #expect(updated?.title == "Example B")
        #expect(updated?.tabs == [updatedTab])

        try await store.archive(id: created.id)
        #expect(try await store.list().isEmpty)

        try await store.delete(id: created.id)
        #expect(try await store.get(id: created.id) == nil)
    }

    @MainActor
    @Test("BrowserTab snapshots persist WKWebView interactionState")
    func interactionStatePersistence() {
        let tab = BrowserTab()
        let state = NSDictionary(dictionary: [
            "scrollY": NSNumber(value: 812),
            "focusedField": NSString(string: "q")
        ])

        tab.setInteractionStateForTesting(state)
        let snapshot = tab.snapshotForThread(now: Date(timeIntervalSince1970: 300))
        let restored = BrowserTab.unarchivedInteractionState(from: snapshot.interactionState) as? NSDictionary

        #expect(snapshot.id == tab.id)
        #expect((restored?["scrollY"] as? NSNumber)?.intValue == 812)
        #expect(restored?["focusedField"] as? String == "q")
    }

    @Test("Closing a window keeps the Thread persisted")
    func closeWindowDoesNotDeleteThread() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ThreadStore(inMemory: true, scratchRoot: root)
        let thread = try await store.create(
            tabs: [TabSnapshot(url: URL(string: "https://example.com"), title: "Example")],
            isWindowOpen: true
        )

        _ = try await store.markWindowOpen(id: thread.id, isOpen: false)

        let listed = try await store.list()
        #expect(listed.map(\.id) == [thread.id])
        #expect(listed.first?.isWindowOpen == false)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-thread-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
