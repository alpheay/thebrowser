import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("HistoryStore")
struct HistoryStoreTests {
    private static func makeIsolatedStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thebrowser-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("history.sqlite")
        return (HistoryStore(databaseURL: dbURL), dir)
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("recordVisit inserts a single row with the supplied url and title")
    func recordsBasicVisit() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let when = Date(timeIntervalSince1970: 1_715_366_400)
        let inserted = store.recordVisit(
            url: URL(string: "https://example.com/page")!,
            title: "Example",
            now: when
        )
        #expect(inserted)

        let entries = store.listHistory()
        #expect(entries.count == 1)
        let first = try! #require(entries.first)
        #expect(first.url.absoluteString == "https://example.com/page")
        #expect(first.title == "Example")
        #expect(first.visitCount == 1)
        #expect(first.kind == .visit)
        #expect(abs(first.lastVisitedAt.timeIntervalSince(when)) < 1)
    }

    @Test("recordVisit collapses to one row and bumps the count on duplicate URL")
    func collapsesDuplicateURL() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let url = URL(string: "https://example.com/")!
        let t0 = Date(timeIntervalSince1970: 1_715_366_400)
        store.recordVisit(url: url, title: "Example", now: t0)
        store.recordVisit(url: url, title: "Example", now: t0.addingTimeInterval(20))

        let entries = store.listHistory()
        #expect(entries.count == 1)
        #expect(entries.first?.visitCount == 2)
    }

    @Test("updateTitle backfills a real title without bumping the count")
    func updateTitleLeavesCountAlone() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let url = URL(string: "https://example.com/")!
        store.recordVisit(url: url, title: "")
        let updated = store.updateTitle(forURL: url, title: "Example")
        #expect(updated)

        let entries = store.listHistory()
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Example")
        #expect(entries.first?.visitCount == 1)
    }

    @Test("Visits past the dedupe window bump visit_count on the existing row")
    func revisitPastWindowBumpsCount() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let url = URL(string: "https://example.com/")!
        let t0 = Date(timeIntervalSince1970: 1_715_366_400)
        store.recordVisit(url: url, title: "Example", now: t0)
        store.recordVisit(url: url, title: "Example", now: t0.addingTimeInterval(120))

        let entries = store.listHistory()
        #expect(entries.count == 1)
        #expect(entries.first?.visitCount == 2)
    }

    @Test("Skips data:, about:blank, and file:// URLs")
    func skipsDisallowedSchemes() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let dataURL = URL(string: "data:text/html,<p>hi</p>")!
        let aboutURL = URL(string: "about:blank")!
        let fileURL = URL(fileURLWithPath: "/tmp/x.html")
        #expect(!store.recordVisit(url: dataURL, title: "data"))
        #expect(!store.recordVisit(url: aboutURL, title: "about"))
        #expect(!store.recordVisit(url: fileURL, title: "file"))
        #expect(store.count() == 0)
    }

    @Test("listHistory orders by last_visited_at descending")
    func listOrdersByLastVisitedDescending() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let t0 = Date(timeIntervalSince1970: 1_715_366_400)
        store.recordVisit(url: URL(string: "https://a.com")!, title: "A", now: t0)
        store.recordVisit(url: URL(string: "https://b.com")!, title: "B", now: t0.addingTimeInterval(60 * 60))
        store.recordVisit(url: URL(string: "https://c.com")!, title: "C", now: t0.addingTimeInterval(2 * 60 * 60))

        let order = store.listHistory().map(\.title)
        #expect(order == ["C", "B", "A"])
    }

    @Test("searchHistory matches case-insensitively across title and url")
    func searchMatchesTitleAndURL() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.recordVisit(url: URL(string: "https://swift.org/")!, title: "Swift Lang")
        store.recordVisit(url: URL(string: "https://example.com/")!, title: "Example")
        store.recordVisit(url: URL(string: "https://news.example.com/python")!, title: "News")

        let titleMatches = store.searchHistory(query: "swift").map(\.title)
        #expect(titleMatches == ["Swift Lang"])

        let urlMatches = store.searchHistory(query: "PYTHON").map(\.title)
        #expect(urlMatches == ["News"])
    }

    @Test("deleteEntries(host:) wipes every visit on a host (incl. www. prefix)")
    func deleteHostWipesAll() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.recordVisit(url: URL(string: "https://example.com/a")!, title: "A")
        store.recordVisit(url: URL(string: "https://www.example.com/b")!, title: "B")
        store.recordVisit(url: URL(string: "https://other.com/")!, title: "Other")

        let deleted = store.deleteEntries(host: "example.com")
        #expect(deleted)
        let remaining = store.listHistory().map(\.title)
        #expect(remaining == ["Other"])
    }

    @Test("deleteHistory(in:) removes only visits inside the range")
    func deleteRangeBound() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let t0 = Date(timeIntervalSince1970: 1_715_366_400)
        store.recordVisit(url: URL(string: "https://old.com/")!, title: "Old", now: t0)
        store.recordVisit(url: URL(string: "https://recent.com/")!, title: "Recent", now: t0.addingTimeInterval(10_000))

        // Window catches "Recent" only.
        store.deleteHistory(in: t0.addingTimeInterval(5_000)...t0.addingTimeInterval(20_000))
        let titles = store.listHistory().map(\.title)
        #expect(titles == ["Old"])
    }

    @Test("upsertImportedEntry collapses duplicates and sums visit counts")
    func upsertCollapsesDuplicates() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let url = URL(string: "https://wiki.example/article")!
        let visited = Date(timeIntervalSince1970: 1_715_366_400)
        store.upsertImportedEntry(url: url, title: "Article", visitCount: 5, lastVisitedAt: visited)
        store.upsertImportedEntry(
            url: url,
            title: "Article",
            visitCount: 3,
            lastVisitedAt: visited.addingTimeInterval(60 * 60)
        )

        let entries = store.listHistory()
        #expect(entries.count == 1)
        #expect(entries.first?.visitCount == 8)
    }

    @Test("recordSearch inserts a row with kind=search and the query as title")
    func recordsSearch() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        let inserted = store.recordSearch(query: "swift concurrency", engine: "brave")
        #expect(inserted)

        let entries = store.listHistory()
        #expect(entries.count == 1)
        let first = try! #require(entries.first)
        #expect(first.kind == .search)
        #expect(first.isSearch)
        #expect(first.title == "swift concurrency")
        #expect(first.searchEngineLabel == "Brave")
    }

    @Test("Same search query collapses into one row with a bumped count")
    func searchDedupesByQuery() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.recordSearch(query: "swift", engine: "brave")
        store.recordSearch(query: "Swift", engine: "brave")
        store.recordSearch(query: "swift", engine: "brave")

        let entries = store.listHistory()
        #expect(entries.count == 1)
        #expect(entries.first?.visitCount == 3)
    }

    @Test("Same query against different engines stays distinct")
    func searchKeepsEnginesDistinct() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        store.recordSearch(query: "swift", engine: "brave")
        store.recordSearch(query: "swift", engine: "google")

        let entries = store.listHistory()
        #expect(entries.count == 2)
    }

    @Test("recordSearch ignores empty / whitespace-only queries")
    func searchRejectsEmpty() {
        let (store, dir) = Self.makeIsolatedStore()
        defer { Self.cleanup(dir) }

        #expect(!store.recordSearch(query: "", engine: "brave"))
        #expect(!store.recordSearch(query: "   ", engine: "brave"))
        #expect(store.count() == 0)
    }

    @Test("HistoryDateGroup.contains classifies dates into the right buckets")
    func dateGroupBuckets() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: now)!
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now)!

        #expect(HistoryDateGroup.today.contains(now, now: now))
        #expect(HistoryDateGroup.yesterday.contains(yesterday, now: now))
        #expect(HistoryDateGroup.thisWeek.contains(fourDaysAgo, now: now))
        #expect(HistoryDateGroup.older.contains(monthAgo, now: now))

        // Cross-bucket checks — Today should not also count as Yesterday/etc.
        #expect(!HistoryDateGroup.today.contains(yesterday, now: now))
        #expect(!HistoryDateGroup.thisWeek.contains(now, now: now))
        #expect(!HistoryDateGroup.older.contains(fourDaysAgo, now: now))
    }
}
