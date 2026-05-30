import Foundation
import Testing
@testable import TheBrowser

/// Exercises the real SQLite path (schema, FTS5, ranking, filters, deletion)
/// against a throwaway database file — the pure-logic suites can't catch a SQL
/// typo or a broken FTS query.
@Suite("RecallStore integration")
struct RecallStoreTests {
    private func makeStore() -> (RecallStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-test-\(UUID().uuidString)", isDirectory: true)
        return (RecallStore(databaseURL: dir.appendingPathComponent("recall.sqlite")), dir)
    }

    private func page(_ urlString: String, text: String, host: String, daysAgo: Int = 0) -> CapturedPage {
        CapturedPage(
            url: URL(string: urlString)!,
            title: "Title for \(urlString)",
            host: host,
            text: text,
            wordCount: RecallChunker.wordCount(text),
            lang: nil,
            dwellSeconds: 8,
            capturedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        )
    }

    private func index(_ store: RecallStore, _ page: CapturedPage) async {
        await store.index(
            page,
            chunks: RecallChunker.chunks(for: page.text),
            chunkEmbeddings: nil,
            pageEmbedding: nil
        )
    }

    private let article = "Transformers use self-attention to weigh tokens across a sequence. "
        + String(repeating: "They have become the dominant deep learning architecture for language. ", count: 8)

    @Test("Indexes a page and finds it by keyword")
    func indexAndSearch() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = page("https://example.com/transformers", text: article, host: "example.com")
        await index(store, p)

        let hits = await store.search(
            RecallQueryPlanner.parse("transformers attention"), queryVector: nil, limit: 5
        )
        #expect(hits.contains { $0.url == p.url })

        let stats = await store.stats()
        #expect(stats.documentCount == 1)
        #expect(stats.chunkCount >= 1)
    }

    @Test("Re-indexing the same content bumps the view count, not the row count")
    func reindexBumps() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = page("https://example.com/a", text: article, host: "example.com")
        await index(store, p)
        await index(store, p)
        let stats = await store.stats()
        #expect(stats.documentCount == 1)
        let hits = await store.search(RecallQueryPlanner.parse("transformers"), queryVector: nil, limit: 5)
        #expect(hits.first?.visitCount == 2)
    }

    @Test("Host filter narrows results to one site")
    func hostFilter() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await index(store, page("https://example.com/r", text: "The quarterly report covers revenue and growth. " + article, host: "example.com"))
        await index(store, page("https://other.com/r", text: "The quarterly report covers revenue and growth. " + article, host: "other.com"))

        let hits = await store.search(
            RecallQueryPlanner.parse("report on example.com"), queryVector: nil, limit: 10
        )
        #expect(hits.allSatisfy { $0.host == "example.com" })
        #expect(hits.isEmpty == false)
    }

    @Test("Temporal filter excludes older pages")
    func temporalFilter() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await index(store, page("https://example.com/new", text: "weekly standup notes. " + article, host: "example.com", daysAgo: 0))
        await index(store, page("https://example.com/old", text: "weekly standup notes. " + article, host: "example.com", daysAgo: 30))

        let hits = await store.search(
            RecallQueryPlanner.parse("standup last 3 days"), queryVector: nil, limit: 10
        )
        #expect(hits.contains { $0.url.absoluteString.hasSuffix("/new") })
        #expect(hits.contains { $0.url.absoluteString.hasSuffix("/old") } == false)
    }

    @Test("Deleting a URL purges its passages")
    func deleteByURL() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = page("https://example.com/gone", text: article, host: "example.com")
        await index(store, p)
        await store.delete(.urls([p.url.absoluteString]))

        let hits = await store.search(RecallQueryPlanner.parse("transformers"), queryVector: nil, limit: 5)
        #expect(hits.isEmpty)
        let stats = await store.stats()
        #expect(stats.documentCount == 0)
        #expect(stats.chunkCount == 0)
    }

    @Test("Clear-all empties the index")
    func deleteAll() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await index(store, page("https://a.com/1", text: article, host: "a.com"))
        await index(store, page("https://b.com/2", text: article, host: "b.com"))
        await store.delete(.all)
        let stats = await store.stats()
        #expect(stats.documentCount == 0)
    }
}
