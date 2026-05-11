import Foundation

/// One captured copy event — text plus the attribution context needed to
/// cite it later. The `id` is generated at capture time and used as the
/// stable key in ``CitedClipboardStore``.
struct CitedClip: Identifiable, Equatable, Hashable {
    let id: String
    var text: String
    var sourceURL: String
    var sourceTitle: String
    var pageDomain: String
    var timestamp: Date
    var sentenceBefore: String
    var sentenceAfter: String
    var copiedFromTabTitle: String

    init(
        id: String = UUID().uuidString,
        text: String,
        sourceURL: String = "",
        sourceTitle: String = "",
        pageDomain: String = "",
        timestamp: Date = Date(),
        sentenceBefore: String = "",
        sentenceAfter: String = "",
        copiedFromTabTitle: String = ""
    ) {
        self.id = id
        self.text = text
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.pageDomain = pageDomain
        self.timestamp = timestamp
        self.sentenceBefore = sentenceBefore
        self.sentenceAfter = sentenceAfter
        self.copiedFromTabTitle = copiedFromTabTitle
    }

    /// One-line preview of the clip body, with whitespace collapsed and
    /// length capped — used in the popover and Settings list.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count > 140 {
            return String(collapsed.prefix(140)) + "…"
        }
        return collapsed
    }

    /// Best human-facing source label — page title if known, else the
    /// page's domain. Returns an empty string when neither is available so
    /// formatters can collapse the citation gracefully (the URL itself
    /// lives in its own slot).
    var sourceLabel: String {
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return pageDomain
    }
}

/// Citation rendering options exposed in the popover. Each case knows how to
/// turn a `CitedClip` into a paste-ready string via ``CitedClipFormatter``.
enum CitedClipFormat: String, CaseIterable, Identifiable {
    case markdownBlockquote
    case markdownInline
    case footnote
    case apa
    case quoteBlock
    case plain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .markdownBlockquote: "Markdown blockquote"
        case .markdownInline: "Markdown inline"
        case .footnote: "Footnote"
        case .apa: "APA"
        case .quoteBlock: "Quote block"
        case .plain: "Plain"
        }
    }

    /// SF Symbol used for the format chip / submenu row.
    var symbolName: String {
        switch self {
        case .markdownBlockquote: "text.quote"
        case .markdownInline: "link"
        case .footnote: "asterisk"
        case .apa: "graduationcap"
        case .quoteBlock: "quote.opening"
        case .plain: "doc.plaintext"
        }
    }
}

/// Markdown-specific style: applies only to the smart-paste rewriter, which
/// picks between blockquote and inline when it auto-rewrites the plain-text
/// rep on app activation.
enum CitedMarkdownStyle: String, CaseIterable, Identifiable {
    case blockquote
    case inline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blockquote: "Blockquote"
        case .inline: "Inline link"
        }
    }

    var pasteFormat: CitedClipFormat {
        switch self {
        case .blockquote: .markdownBlockquote
        case .inline: .markdownInline
        }
    }
}

/// Citation chrome for non-markdown destinations (rich-text apps, plain
/// text fallbacks). Bracketed link wraps the source as `[Title](URL)`;
/// footnote moves the source to a trailing `[^1]: ...` line.
enum CitedCitationStyle: String, CaseIterable, Identifiable {
    case bracketed
    case footnote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bracketed: "Bracketed link"
        case .footnote: "Footnote"
        }
    }
}
