import AppKit
import Foundation
import Testing
@preconcurrency import WebKit
@testable import TheBrowser

@Suite("PageArchive")
struct PageArchiveTests {
    @MainActor
    @Test("Round-trips a visit through the archive")
    func roundTripsVisit() throws {
        let archive = Self.makeIsolatedArchive()
        let visit = try #require(archive.record(
            visit: PageArchiveVisitCapture(
                url: URL(string: "https://example.com/article")!,
                title: "Example",
                domHTML: "<html><body><h1>Hello</h1></body></html>",
                screenshotData: Data([0x89, 0x50, 0x4E, 0x47]),
                networkEvents: [
                    PageArchiveNetworkEvent(
                        method: "POST",
                        url: "https://example.com/api",
                        status: 200,
                        type: "fetch",
                        requestHeaders: ["accept": "application/json"],
                        responseHeaders: ["content-type": "application/json"],
                        requestBody: #"{"q":"swift"}"#,
                        responseBody: #"{"ok":true}"#,
                        durationMS: 12.5
                    )
                ]
            )
        ))

        let visits = archive.query(url: "example.com", limit: 10)
        #expect(visits.map(\.id) == [visit.id])
        #expect(visits[0].networkLogCount == 1)

        let details = try #require(archive.get(visitID: visit.id))
        #expect(details.domHTML.contains("<h1>Hello</h1>"))
        #expect(FileManager.default.fileExists(atPath: details.screenshotURL.path))
        #expect(details.networkLog.count == 1)
        #expect(details.networkLog[0].method == "POST")
        #expect(details.networkLog[0].body?.contains("ok") == true)
    }

    @MainActor
    @Test("Content-addressed blobs deduplicate identical bytes")
    func contentAddressedBlobDedup() throws {
        let archive = Self.makeIsolatedArchive()
        let bytes = Data("same rendered DOM".utf8)

        let first = try #require(archive.storeBlob(bytes))
        let second = try #require(archive.storeBlob(bytes))

        #expect(first == second)
        #expect(archive.blobFileCount() == 1)
        #expect(archive.get(blobHash: first) == bytes)
    }

    @MainActor
    @Test("LRU prune removes old visits when the cap is exceeded")
    func lruPruneFiresOverCap() throws {
        let archive = Self.makeIsolatedArchive(maxBytes: 1_500)
        let olderDate = Date(timeIntervalSince1970: 1_000)
        let newerDate = Date(timeIntervalSince1970: 2_000)

        _ = archive.record(
            visit: PageArchiveVisitCapture(
                url: URL(string: "https://example.com/older")!,
                title: "Older",
                timestamp: olderDate,
                domData: Data(repeating: 1, count: 900),
                screenshotData: Data([1])
            )
        )
        let newer = try #require(archive.record(
            visit: PageArchiveVisitCapture(
                url: URL(string: "https://example.com/newer")!,
                title: "Newer",
                timestamp: newerDate,
                domData: Data(repeating: 2, count: 900),
                screenshotData: Data([2])
            )
        ))

        let visits = archive.query(url: "example.com", limit: 10)
        #expect(visits.map(\.id) == [newer.id])
        #expect(visits[0].url.hasSuffix("/newer"))
    }

    @MainActor
    @Test("Archive native tools query and get visits")
    func nativeArchiveTools() async throws {
        let archive = Self.makeIsolatedArchive()
        let visit = try #require(archive.record(
            visit: PageArchiveVisitCapture(
                url: URL(string: "https://example.com/tool")!,
                title: "Tool Visit",
                domHTML: "<html><body>tool dom</body></html>",
                screenshotData: Data([3])
            )
        ))

        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") },
            queryArchive: { url, sinceTs, limit in
                archive.query(url: url, sinceTs: sinceTs, limit: limit)
            },
            getArchiveVisit: { id in
                archive.get(visitID: id)
            }
        )

        let queryCall = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"archive.query","url":"example.com","limit":5}"#))
        let query = await executor.execute(queryCall)
        #expect(query.succeeded)
        #expect(query.content.contains("Visit ID: \(visit.id)"))

        let getCall = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"archive.get","visit_id":\#(visit.id)}"#))
        let get = await executor.execute(getCall)
        #expect(get.succeeded)
        #expect(get.content.contains("tool dom"))
        #expect(get.content.contains("Screenshot: "))
    }

    @MainActor
    @Test("WKWebView fixture captures fetch and XHR network rows")
    func webViewFixtureCapturesNetworkRows() async throws {
        let archive = Self.makeIsolatedArchive()
        let tab = BrowserTab(pageArchive: archive)
        let targetURL = URL(string: "https://archive.test/fixture.html")!
        tab.isHome = false
        tab.url = targetURL
        tab.title = "Fixture"

        let webView = tab.webView
        webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        webView.loadHTMLString(Self.fixtureHTML, baseURL: targetURL)

        let details = await Self.waitForArchivedVisit(in: archive, url: "archive.test") { details in
            let types = Set(details.networkLog.map(\.type))
            return types.contains("fetch") && types.contains("xmlhttprequest")
        }

        guard let details else {
            Issue.record("Expected WKWebView fixture to write fetch and XHR rows")
            return
        }

        #expect(details.domHTML.contains("Archive Fixture"))
        #expect(details.networkLog.contains { $0.type == "fetch" })
        #expect(details.networkLog.contains { $0.type == "xmlhttprequest" })
    }

    @MainActor
    private static func makeIsolatedArchive(maxBytes: Int64? = nil) -> PageArchive {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheBrowser-PageArchiveTests-\(UUID().uuidString)", isDirectory: true)
        return PageArchive(rootURL: root, maxArchiveSizeBytes: maxBytes)
    }

    @MainActor
    private static func waitForArchivedVisit(
        in archive: PageArchive,
        url: String,
        predicate: (PageArchiveVisitDetails) -> Bool
    ) async -> PageArchiveVisitDetails? {
        for _ in 0..<100 {
            for visit in archive.query(url: url, limit: 5) {
                if let details = archive.get(visitID: visit.id), predicate(details) {
                    return details
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private static let fixtureHTML = """
    <!doctype html>
    <html>
    <head><title>Archive Fixture</title></head>
    <body>
      <h1>Archive Fixture</h1>
      <img alt="tiny" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
      <script>
      window.addEventListener('load', async () => {
        await fetch('data:application/json,%7B%22ok%22%3Atrue%7D');
        const xhr = new XMLHttpRequest();
        xhr.open('GET', 'data:text/plain,xhr-ok');
        xhr.onload = () => document.body.setAttribute('data-xhr', xhr.responseText || 'done');
        xhr.send();
      });
      </script>
    </body>
    </html>
    """
}
