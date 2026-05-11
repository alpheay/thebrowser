import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("CitedClipboardStore")
struct CitedClipboardStoreTests {
    private static func makeIsolatedStore() -> (CitedClipboardStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("clipboard.sqlite")
        return (CitedClipboardStore(databaseURL: dbURL), dir)
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func sampleClip(
        id: String = UUID().uuidString,
        text: String = "sample",
        timestamp: Date = Date()
    ) -> CitedClip {
        CitedClip(
            id: id,
            text: text,
            sourceURL: "https://example.com/page",
            sourceTitle: "Example",
            pageDomain: "example.com",
            timestamp: timestamp,
            sentenceBefore: "before",
            sentenceAfter: "after",
            copiedFromTabTitle: "Example"
        )
    }

    @Test("insert + recentClips round-trips a single clip with all fields intact")
    func insertRoundTrip() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let when = Date(timeIntervalSince1970: 1_715_366_400)
        let clip = Self.sampleClip(id: "abc", text: "Hello, world.", timestamp: when)
        store.insert(clip)

        let reloaded = store.recentClips()
        #expect(reloaded.count == 1)
        let first = try! #require(reloaded.first)
        #expect(first.id == "abc")
        #expect(first.text == "Hello, world.")
        #expect(first.sourceURL == "https://example.com/page")
        #expect(first.sourceTitle == "Example")
        #expect(first.pageDomain == "example.com")
        #expect(first.sentenceBefore == "before")
        #expect(first.sentenceAfter == "after")
        // Timestamps round-trip with millisecond precision via ISO-8601;
        // a one-second tolerance keeps the test robust to fractional drift.
        #expect(abs(first.timestamp.timeIntervalSince(when)) < 1)
    }

    @Test("recentClips returns newest entries first, ordered by timestamp")
    func recentClipsOrdersByTimestampDescending() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let now = Date()
        store.insert(Self.sampleClip(id: "old", text: "old", timestamp: now.addingTimeInterval(-300)))
        store.insert(Self.sampleClip(id: "mid", text: "mid", timestamp: now.addingTimeInterval(-100)))
        store.insert(Self.sampleClip(id: "new", text: "new", timestamp: now))

        let order = store.recentClips().map(\.id)
        #expect(order == ["new", "mid", "old"])
    }

    @Test("Insert beyond the 200-entry cap evicts the oldest rows")
    func insertCapsToMaxEntries() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        // Use a base date and walk forward by 1s per entry — gives every clip
        // a unique, ordered timestamp that's stable across runs.
        let base = Date(timeIntervalSince1970: 1_000_000_000)
        let total = CitedClipboardStore.maxEntries + 25
        for index in 0..<total {
            store.insert(Self.sampleClip(
                id: "id-\(index)",
                text: "clip \(index)",
                timestamp: base.addingTimeInterval(Double(index))
            ))
        }

        let stored = store.recentClips()
        #expect(stored.count == CitedClipboardStore.maxEntries)
        // Newest first: ids should be the last 200 we inserted.
        let firstID = stored.first?.id
        let lastID = stored.last?.id
        #expect(firstID == "id-\(total - 1)")
        #expect(lastID == "id-\(total - CitedClipboardStore.maxEntries)")
    }

    @Test("delete by id removes only the matching row")
    func deleteByID() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let now = Date()
        store.insert(Self.sampleClip(id: "keep", text: "keep", timestamp: now))
        store.insert(Self.sampleClip(id: "drop", text: "drop", timestamp: now.addingTimeInterval(1)))

        store.delete(id: "drop")

        let remainingIDs = store.recentClips().map(\.id)
        #expect(remainingIDs == ["keep"])
    }

    @Test("clearAll empties the table without dropping the schema")
    func clearAllDoesNotDropSchema() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.insert(Self.sampleClip(id: "x"))
        store.clearAll()
        #expect(store.recentClips().isEmpty)

        // Confirm the schema is still alive by inserting after the clear.
        store.insert(Self.sampleClip(id: "y"))
        #expect(store.recentClips().map(\.id) == ["y"])
    }

    @Test("count() reflects the row total")
    func countMatchesRows() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        #expect(store.count() == 0)
        store.insert(Self.sampleClip(id: "1"))
        store.insert(Self.sampleClip(id: "2"))
        #expect(store.count() == 2)
    }

    @Test("didChange notification fires on insert + delete + clearAll")
    func notificationFires() async {
        // The store posts on `NotificationCenter.default`, which is shared
        // with every other store instance the test suite creates in
        // parallel — track the delta from a baseline taken before our own
        // operations rather than the absolute count.
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: CitedClipboardStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { counter.bump() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await Task.yield()
        let baseline = counter.value

        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.insert(Self.sampleClip(id: "i"))
        store.delete(id: "i")
        store.clearAll()
        // Yield so any queued main-queue blocks land before we read.
        await Task.yield()
        #expect(counter.value - baseline >= 3)
    }
}

/// Simple MainActor-bound counter for notification deltas. The observer's
/// queue is `.main`, so all reads and writes happen on the main thread.
@MainActor
private final class NotificationCounter {
    var value: Int = 0
    func bump() { value += 1 }
}
