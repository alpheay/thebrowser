import Foundation

/// Pure renderers from a ``CitedClip`` to a paste-ready string for every
/// ``CitedClipFormat``. Intentionally side-effect free so it's easy to test
/// and to reuse from both the popover and the smart-paste rewriter.
enum CitedClipFormatter {
    static func render(_ clip: CitedClip, as format: CitedClipFormat) -> String {
        switch format {
        case .markdownBlockquote: return markdownBlockquote(clip)
        case .markdownInline: return markdownInline(clip)
        case .footnote: return footnote(clip)
        case .apa: return apa(clip)
        case .quoteBlock: return quoteBlock(clip)
        case .plain: return clip.text
        }
    }

    // MARK: - Per-format renderers

    private static func markdownBlockquote(_ clip: CitedClip) -> String {
        let body = normalizeForMarkdown(clip.text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.isEmpty ? ">" : "> " + line }
            .joined(separator: "\n")

        let citation: String
        switch (clip.sourceLabel.isEmpty, clip.sourceURL.isEmpty) {
        case (false, false): citation = "— [\(escapeMarkdownLinkText(clip.sourceLabel))](\(clip.sourceURL))"
        case (false, true): citation = "— \(clip.sourceLabel)"
        case (true, false): citation = "— <\(clip.sourceURL)>"
        case (true, true): citation = ""
        }

        if citation.isEmpty {
            return body
        }
        return body + "\n\n" + citation
    }

    private static func markdownInline(_ clip: CitedClip) -> String {
        let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clip.sourceURL.isEmpty {
            return text
        }
        return "[\(escapeMarkdownLinkText(text))](\(clip.sourceURL))"
    }

    private static func footnote(_ clip: CitedClip) -> String {
        let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clip.sourceURL.isEmpty || !clip.sourceLabel.isEmpty else {
            return text
        }
        let trail: String
        if !clip.sourceLabel.isEmpty && !clip.sourceURL.isEmpty {
            trail = "[^1]: \(clip.sourceLabel) — \(clip.sourceURL)"
        } else if !clip.sourceURL.isEmpty {
            trail = "[^1]: \(clip.sourceURL)"
        } else {
            trail = "[^1]: \(clip.sourceLabel)"
        }
        return "\(text)[^1]\n\n\(trail)"
    }

    private static func apa(_ clip: CitedClip) -> String {
        let quote = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: clip.timestamp)
        let attribution = clip.pageDomain.isEmpty ? clip.sourceLabel : clip.pageDomain
        let header = attribution.isEmpty ? "" : "(\(attribution), \(year))."
        let parts: [String] = [
            "\u{201C}\(quote)\u{201D}\(header.isEmpty ? "" : " \(header)")",
            clip.sourceURL.isEmpty ? "" : "Retrieved from \(clip.sourceURL)"
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func quoteBlock(_ clip: CitedClip) -> String {
        let quote = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution: String
        switch (clip.sourceLabel.isEmpty, clip.sourceURL.isEmpty) {
        case (false, false): attribution = " — \(clip.sourceLabel) (\(clip.sourceURL))"
        case (false, true): attribution = " — \(clip.sourceLabel)"
        case (true, false): attribution = " — \(clip.sourceURL)"
        case (true, true): attribution = ""
        }
        return "\u{201C}\(quote)\u{201D}\(attribution)"
    }

    /// Rich-text destinations (Notes, Mail, Pages) get `(via Title)` appended
    /// after the quote — used by the HTML representation so the citation
    /// survives a paste even when the destination strips the link.
    static func richTextFooter(_ clip: CitedClip) -> String {
        let label = clip.sourceLabel
        guard !label.isEmpty else { return "" }
        return " (via \(label))"
    }

    // MARK: - Helpers

    /// Collapses runs of blank lines to a single blank line so multi-paragraph
    /// selections don't render with awkwardly large gaps in markdown
    /// blockquotes. Single line breaks inside a paragraph are preserved.
    private static func normalizeForMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes the closing bracket so a `]` inside the link text doesn't
    /// terminate the markdown link prematurely.
    private static func escapeMarkdownLinkText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
