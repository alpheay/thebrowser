import Foundation
import Testing
@testable import TheBrowser

@Suite("Recall support")
struct RecallSupportTests {
    @Test("Host normalization lowercases and drops www")
    func hostNormalize() {
        #expect(RecallHost.normalize("www.NYTimes.com") == "nytimes.com")
        #expect(RecallHost.normalize("Example.COM") == "example.com")
        #expect(RecallHost.normalize(url: URL(string: "https://www.Stripe.com/pricing")!) == "stripe.com")
        #expect(RecallHost.normalize(nil) == "")
    }

    @Test("FTS match query builds OR-of-prefixes, nil when empty")
    func ftsMatch() {
        #expect(RecallStore.ftsMatchQuery("Swift Concurrency!") == "\"swift\"* OR \"concurrency\"*")
        #expect(RecallStore.ftsMatchQuery("a") == nil)
        #expect(RecallStore.ftsMatchQuery("   ") == nil)
    }

    @Test("Embedding blob round-trips through Data")
    func blobRoundTrip() {
        let vector: [Float] = [1.5, -2.0, 3.25, 0, 42.0]
        #expect(Data(floats: vector).toFloatArray() == vector)
        #expect(Data(floats: []).toFloatArray() == [])
    }

    @Test("Snippet collapses whitespace and truncates")
    func snippet() {
        let messy = "  hello\n\n   world \t  "
        #expect(RecallStore.snippet(messy) == "hello world")
        let long = String(repeating: "x", count: 500)
        let clipped = RecallStore.snippet(long, limit: 100)
        #expect(clipped.count <= 101)
        #expect(clipped.hasSuffix("…"))
    }

    @Test("Content hash is stable and content-sensitive")
    func contentHash() {
        let page = CapturedPage(
            url: URL(string: "https://example.com")!, title: "T", host: "example.com",
            text: "hello world", wordCount: 2, lang: nil, dwellSeconds: 8, capturedAt: Date()
        )
        #expect(page.contentHash == RecallHashing.hash("hello world"))
        #expect(RecallHashing.hash("a") != RecallHashing.hash("b"))
    }
}
