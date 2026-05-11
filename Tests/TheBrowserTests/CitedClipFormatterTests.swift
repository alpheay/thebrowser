import Foundation
import Testing
@testable import TheBrowser

@Suite("CitedClipFormatter")
struct CitedClipFormatterTests {
    private static func sampleClip(
        text: String = "WebKit treats `setData` for custom MIME types\nas a custom NSPasteboard UTI.",
        url: String = "https://webkit.org/blog/2026/clipboard-data/",
        title: String = "Clipboard data in WebKit",
        domain: String = "webkit.org",
        timestamp: Date = Date(timeIntervalSince1970: 1_715_366_400) // 2024-05-10
    ) -> CitedClip {
        CitedClip(
            id: "fixed-id",
            text: text,
            sourceURL: url,
            sourceTitle: title,
            pageDomain: domain,
            timestamp: timestamp,
            sentenceBefore: "Earlier in the post:",
            sentenceAfter: "Later, the post explains caveats.",
            copiedFromTabTitle: title
        )
    }

    @Test("Markdown blockquote renders body lines with > prefixes and a citation footer")
    func markdownBlockquote() {
        let clip = Self.sampleClip()
        let rendered = CitedClipFormatter.render(clip, as: .markdownBlockquote)
        #expect(rendered.contains("> WebKit treats `setData` for custom MIME types"))
        #expect(rendered.contains("> as a custom NSPasteboard UTI."))
        #expect(rendered.contains("— [Clipboard data in WebKit](https://webkit.org/blog/2026/clipboard-data/)"))
    }

    @Test("Markdown blockquote falls back to bare URL when title is missing")
    func markdownBlockquoteFallsBackToBareURL() {
        let clip = Self.sampleClip(title: "", domain: "")
        let rendered = CitedClipFormatter.render(clip, as: .markdownBlockquote)
        #expect(rendered.contains("— <https://webkit.org/blog/2026/clipboard-data/>"))
    }

    @Test("Markdown inline wraps the quote as a single link")
    func markdownInline() {
        let clip = Self.sampleClip(text: "Custom MIME types land on NSPasteboard.")
        let rendered = CitedClipFormatter.render(clip, as: .markdownInline)
        #expect(rendered == "[Custom MIME types land on NSPasteboard.](https://webkit.org/blog/2026/clipboard-data/)")
    }

    @Test("Markdown inline escapes a closing bracket inside the link text")
    func markdownInlineEscapesBracket() {
        let clip = Self.sampleClip(text: "Foo [bar] baz")
        let rendered = CitedClipFormatter.render(clip, as: .markdownInline)
        #expect(rendered == "[Foo [bar\\] baz](https://webkit.org/blog/2026/clipboard-data/)")
    }

    @Test("Footnote attaches a [^1] marker and a trailing definition line")
    func footnote() {
        let clip = Self.sampleClip(text: "Custom MIME types land on NSPasteboard.")
        let rendered = CitedClipFormatter.render(clip, as: .footnote)
        #expect(rendered.contains("Custom MIME types land on NSPasteboard.[^1]"))
        #expect(rendered.contains("[^1]: Clipboard data in WebKit — https://webkit.org/blog/2026/clipboard-data/"))
    }

    @Test("APA renders “quote” (domain, year). Retrieved from URL")
    func apa() {
        let clip = Self.sampleClip(text: "Custom MIME types land on NSPasteboard.")
        let rendered = CitedClipFormatter.render(clip, as: .apa)
        #expect(rendered.contains("\u{201C}Custom MIME types land on NSPasteboard.\u{201D}"))
        #expect(rendered.contains("(webkit.org,"))
        #expect(rendered.contains("Retrieved from https://webkit.org/blog/2026/clipboard-data/"))
    }

    @Test("Quote block emits curly quotes plus inline source attribution")
    func quoteBlock() {
        let clip = Self.sampleClip(text: "Custom MIME types land on NSPasteboard.")
        let rendered = CitedClipFormatter.render(clip, as: .quoteBlock)
        #expect(rendered == "\u{201C}Custom MIME types land on NSPasteboard.\u{201D} — Clipboard data in WebKit (https://webkit.org/blog/2026/clipboard-data/)")
    }

    @Test("Plain returns the body unchanged")
    func plain() {
        let body = "Some \"unmodified\" body."
        let clip = Self.sampleClip(text: body)
        #expect(CitedClipFormatter.render(clip, as: .plain) == body)
    }

    @Test("Multi-paragraph blockquote collapses runs of blank lines to a single break")
    func blockquoteCollapsesParagraphs() {
        let clip = Self.sampleClip(text: "Para one.\n\n\n\nPara two.\n\n\nPara three.")
        let rendered = CitedClipFormatter.render(clip, as: .markdownBlockquote)
        // Each paragraph is one prefix-line; they're separated by `>` (empty line).
        let body = rendered.split(separator: "\n\n").first.map(String.init) ?? ""
        let expectedLines = ["> Para one.", ">", "> Para two.", ">", "> Para three."]
        #expect(body == expectedLines.joined(separator: "\n"))
    }

    @Test("richTextFooter returns ` (via Title)` when a title is present")
    func richTextFooterUsesTitle() {
        let clip = Self.sampleClip()
        #expect(CitedClipFormatter.richTextFooter(clip) == " (via Clipboard data in WebKit)")
    }

    @Test("richTextFooter returns empty when no title or domain is available")
    func richTextFooterEmptyFallback() {
        let clip = Self.sampleClip(title: "", domain: "")
        #expect(CitedClipFormatter.richTextFooter(clip) == "")
    }
}
