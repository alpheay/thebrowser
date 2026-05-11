import Foundation
import Testing
@testable import TheBrowser

@Suite("HoverPreviewExtractor")
struct HoverPreviewExtractorTests {
    @Test("Pulls <title>, description, favicon, and stripped body from a normal HTML page")
    func parsesEverydayPage() throws {
        let html = """
        <html>
        <head>
            <title>Example Page</title>
            <meta name="description" content="A description for the example page.">
            <link rel="icon" href="/favicon.ico">
            <style>body { color: red; }</style>
            <script>console.log('skip me');</script>
        </head>
        <body>
            <nav>Skip this</nav>
            <article>
                <h1>Hello world</h1>
                <p>This is a paragraph.</p>
                <p>And another paragraph.</p>
            </article>
            <footer>Skip the footer too</footer>
        </body>
        </html>
        """
        let parsed = HoverPreviewExtractor.parse(html: html, sourceURL: URL(string: "https://example.com/page")!)
        #expect(parsed.title == "Example Page")
        #expect(parsed.description == "A description for the example page.")
        #expect(parsed.faviconURL?.absoluteString == "https://example.com/favicon.ico")
        #expect(parsed.body.contains("Hello world"))
        #expect(parsed.body.contains("This is a paragraph."))
        #expect(!parsed.body.contains("Skip the footer too"))
        #expect(!parsed.body.contains("Skip this"))
        #expect(!parsed.body.contains("color: red"))
        #expect(!parsed.body.contains("console.log"))
    }

    @Test("Prefers og:description when present and unescapes HTML entities in title")
    func prefersOpenGraph() {
        let html = """
        <html><head>
            <title>Smith &amp; Jones</title>
            <meta name="description" content="Default description">
            <meta property="og:description" content="The OpenGraph one">
        </head><body><p>Body.</p></body></html>
        """
        let parsed = HoverPreviewExtractor.parse(html: html, sourceURL: URL(string: "https://example.com/")!)
        #expect(parsed.title == "Smith & Jones")
        #expect(parsed.description == "The OpenGraph one")
    }

    @Test("Falls back to source host when no title is declared")
    func fallsBackToHost() {
        let html = "<html><body><p>Nothing here.</p></body></html>"
        let parsed = HoverPreviewExtractor.parse(html: html, sourceURL: URL(string: "https://news.example.org/article/123")!)
        #expect(parsed.title == "news.example.org")
    }
}

@Suite("HoverPreviewCache")
struct HoverPreviewCacheTests {
    @MainActor
    @Test("LRU eviction keeps the most recently used entries")
    func evictsOldest() {
        let cache = HoverPreviewCache(capacity: 3)
        let urls = (1...4).map { URL(string: "https://example.com/\($0)")! }
        for url in urls {
            cache.setContent(makeContent(for: url), for: url)
        }
        // First URL should have been evicted (capacity 3, inserted 4).
        #expect(cache.value(for: urls[0]) == nil)
        #expect(cache.value(for: urls[1]) != nil)
        #expect(cache.value(for: urls[2]) != nil)
        #expect(cache.value(for: urls[3]) != nil)
    }

    @MainActor
    @Test("Fragment-only URL variations share the same cache slot")
    func fragmentsShareSlot() {
        let cache = HoverPreviewCache(capacity: 5)
        let plain = URL(string: "https://example.com/post")!
        let fragment = URL(string: "https://example.com/post#section-2")!
        cache.setContent(makeContent(for: plain), for: plain)
        #expect(cache.value(for: fragment) != nil)
    }

    private func makeContent(for url: URL) -> HoverPreviewContent {
        HoverPreviewContent(
            url: url,
            finalURL: url,
            title: "T",
            description: "D",
            bodyText: "B",
            faviconURL: nil,
            wordCount: 1
        )
    }
}

@Suite("HoverPreviewPrefetcher blocklist")
struct HoverPreviewPrefetcherTests {
    @MainActor
    @Test("Bare host pattern matches host and subdomains")
    func bareHostMatches() {
        let prefetcher = HoverPreviewPrefetcher(cache: HoverPreviewCache())
        prefetcher.updateBlocklist("example.com")
        #expect(prefetcher.isBlocked(url: URL(string: "https://example.com/foo")!))
        #expect(prefetcher.isBlocked(url: URL(string: "https://news.example.com/foo")!))
        #expect(!prefetcher.isBlocked(url: URL(string: "https://other.org/")!))
    }

    @MainActor
    @Test("Wildcard pattern requires the eTLD to match")
    func wildcardMatches() {
        let prefetcher = HoverPreviewPrefetcher(cache: HoverPreviewCache())
        prefetcher.updateBlocklist("*.private.test")
        #expect(prefetcher.isBlocked(url: URL(string: "https://docs.private.test/x")!))
        #expect(prefetcher.isBlocked(url: URL(string: "https://private.test/")!))
        #expect(!prefetcher.isBlocked(url: URL(string: "https://public.test/")!))
    }
}
