import Foundation
import Testing
@testable import TheBrowser

@Suite("ArtifactMetadata")
struct ArtifactMetadataTests {
    @Test("parses the UTC timestamp prefix from a filename")
    func parsesTimestamp() throws {
        let date = try #require(ArtifactMetadata.parseTimestamp(
            fileName: "2026-05-22_23-56-56_market-brief.html"
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 22)
        #expect(comps.hour == 23)
        #expect(comps.minute == 56)
        #expect(comps.second == 56)
    }

    @Test("returns nil for filenames without a stamp prefix")
    func parseTimestampRejectsNonConforming() {
        #expect(ArtifactMetadata.parseTimestamp(fileName: "notes.html") == nil)
        #expect(ArtifactMetadata.parseTimestamp(fileName: "hello-world-this-is-long.html") == nil)
    }

    @Test("derives a readable fallback title from the slug")
    func desluggedTitle() {
        let title = ArtifactMetadata.desluggedTitle(
            fileName: "2026-05-22_23-56-56_narwhal-facts-editorial-brief.html"
        )
        #expect(title == "Narwhal Facts Editorial Brief")
    }

    @Test("make reads the document <title>, stamp, and size")
    func makeReadsTitleAndDate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("2026-05-22_23-56-56_market-brief.html")
        try "<!doctype html><html><head><title>Market &amp; Brief</title></head><body>hi</body></html>"
            .data(using: .utf8)!.write(to: url)

        let meta = try #require(ArtifactMetadata.make(url: url))
        #expect(meta.id == "2026-05-22_23-56-56_market-brief.html")
        #expect(meta.title == "Market & Brief")
        #expect(meta.fileSize > 0)
        #expect(ArtifactMetadata.parseTimestamp(fileName: meta.id) == meta.createdAt)
    }

    @Test("make ignores non-HTML files")
    func makeIgnoresNonHTML() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note.txt")
        #expect(ArtifactMetadata.make(url: url) == nil)
    }

    @Test("make falls back to the deslugged title when there is no <title>")
    func makeFallsBackToSlug() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("2026-05-22_23-56-56_quarterly-report.html")
        try "<html><body>no head title here</body></html>".data(using: .utf8)!.write(to: url)

        let meta = try #require(ArtifactMetadata.make(url: url))
        #expect(meta.title == "Quarterly Report")
    }
}
