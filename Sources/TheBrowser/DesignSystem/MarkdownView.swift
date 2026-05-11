import SwiftUI

/// Renders a Markdown string with B&W styling. Handles the block-level
/// elements most often produced by chat models: headings, paragraphs,
/// fenced code blocks, ordered/unordered lists, blockquotes, and
/// horizontal rules. Inline styling (bold, italic, inline code, links)
/// is delegated to `AttributedString(markdown:)`.
struct MarkdownView: View {
    let text: String
    /// Optional ordered list of citation URLs. When provided, any `[N]`
    /// pattern (1-indexed) found inside inline text will be styled as a
    /// small clickable citation pill linking to `citations[N-1]`.
    var citations: [URL]? = nil

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, citations: citations)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Block model

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case unorderedList([String])
    case orderedList([String])
    case blockquote(String)
    case horizontalRule
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code = ""
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if !code.isEmpty { code += "\n" }
                    code += lines[i]
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
                continue
            }

            // Heading
            if let (level, headingText) = parseHeading(trimmed) {
                blocks.append(.heading(level: level, text: headingText))
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Blockquote (one or more contiguous "> " lines)
            if trimmed.hasPrefix(">") {
                var quote = stripQuoteMarker(trimmed)
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        quote += "\n" + stripQuoteMarker(t)
                        i += 1
                    } else { break }
                }
                blocks.append(.blockquote(quote))
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isUnorderedListItem(t) {
                        items.append(stripUnorderedListMarker(t))
                        i += 1
                    } else { break }
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list
            if isOrderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isOrderedListItem(t) {
                        items.append(stripOrderedListMarker(t))
                        i += 1
                    } else { break }
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Empty line — separator between paragraphs
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph: collect consecutive non-empty, non-block-starting lines
            var paragraph = line
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isBlockStart(t) { break }
                paragraph += "\n" + lines[i]
                i += 1
            }
            blocks.append(.paragraph(paragraph))
        }

        return blocks
    }

    // Returns (level, text) for ATX-style headings.
    private static func parseHeading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex && s[idx] == "#" && level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[s.index(after: idx)...]))
    }

    private static func isUnorderedListItem(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripUnorderedListMarker(_ s: String) -> String {
        if s.count >= 2 {
            let prefix = s.prefix(2)
            if prefix == "- " || prefix == "* " || prefix == "+ " {
                return String(s.dropFirst(2))
            }
        }
        return s
    }

    private static func isOrderedListItem(_ s: String) -> Bool {
        var idx = s.startIndex
        var sawDigit = false
        while idx < s.endIndex && s[idx].isNumber {
            idx = s.index(after: idx)
            sawDigit = true
        }
        guard sawDigit, idx < s.endIndex, s[idx] == "." else { return false }
        let next = s.index(after: idx)
        return next < s.endIndex && s[next] == " "
    }

    private static func stripOrderedListMarker(_ s: String) -> String {
        var idx = s.startIndex
        while idx < s.endIndex && s[idx].isNumber {
            idx = s.index(after: idx)
        }
        if idx < s.endIndex && s[idx] == "." {
            idx = s.index(after: idx)
            if idx < s.endIndex && s[idx] == " " {
                idx = s.index(after: idx)
            }
        }
        return String(s[idx...])
    }

    private static func stripQuoteMarker(_ s: String) -> String {
        if s.hasPrefix("> ") { return String(s.dropFirst(2)) }
        if s.hasPrefix(">") { return String(s.dropFirst()) }
        return s
    }

    private static func isBlockStart(_ s: String) -> Bool {
        if s.hasPrefix("```") { return true }
        if parseHeading(s) != nil { return true }
        if s == "---" || s == "***" || s == "___" { return true }
        if s.hasPrefix(">") { return true }
        if isUnorderedListItem(s) { return true }
        if isOrderedListItem(s) { return true }
        return false
    }
}

// MARK: - Block renderer

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var citations: [URL]?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            HeadingView(level: level, text: text, citations: citations)
        case .paragraph(let text):
            InlineText(text: text, citations: citations)
                .lineSpacing(3)
        case .codeBlock(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .unorderedList(let items):
            ListView(items: items, ordered: false, citations: citations)
        case .orderedList(let items):
            ListView(items: items, ordered: true, citations: citations)
        case .blockquote(let text):
            BlockquoteView(text: text, citations: citations)
        case .horizontalRule:
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

private struct HeadingView: View {
    let level: Int
    let text: String
    var citations: [URL]?

    var body: some View {
        InlineText(text: text, citations: citations)
            .font(.system(size: fontSize, weight: .semibold))
            .padding(.top, level <= 2 ? 4 : 1)
    }

    private var fontSize: CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 14.5
        default: return 13.5
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Palette.textFaint)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.top, language == nil ? 10 : 4)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.bgSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct ListView: View {
    let items: [String]
    let ordered: Bool
    var citations: [URL]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: 13, weight: ordered ? .medium : .bold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 18, alignment: .trailing)
                    InlineText(text: item, citations: citations)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct BlockquoteView: View {
    let text: String
    var citations: [URL]?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Palette.strokeStrong)
                .frame(width: 2)
            InlineText(text: text, citations: citations)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineSpacing(3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Inline (uses AttributedString markdown for bold/italic/code/links)

private struct InlineText: View {
    let text: String
    var citations: [URL]? = nil

    var body: some View {
        Text(formatted)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.textPrimary)
            .textSelection(.enabled)
    }

    private var formatted: AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(text)
        }

        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = .system(size: 12.5, weight: .medium, design: .monospaced)
                attributed[run.range].foregroundColor = Palette.textPrimary
                attributed[run.range].backgroundColor = Color.white.opacity(0.07)
            }
            if run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = Palette.textPrimary
            }
        }

        if let citations, !citations.isEmpty {
            Self.applyCitations(to: &attributed, urls: citations)
        }

        return attributed
    }

    /// Scan the rendered text for `[N]` patterns and turn each into a small
    /// monospace citation pill linking to `urls[N-1]`. Citations are applied
    /// after the markdown link styling pass so they override any default
    /// underline / size and look distinct from regular inline links.
    private static func applyCitations(to attributed: inout AttributedString, urls: [URL]) {
        let plain = String(attributed.characters)
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        let matches = regex.matches(in: plain, range: nsRange)

        for match in matches {
            guard
                let numberSwiftRange = Range(match.range(at: 1), in: plain),
                let n = Int(plain[numberSwiftRange]),
                n >= 1, n <= urls.count,
                let citationSwiftRange = Range(match.range, in: plain)
            else { continue }

            let lowerOffset = plain.distance(from: plain.startIndex, to: citationSwiftRange.lowerBound)
            let upperOffset = plain.distance(from: plain.startIndex, to: citationSwiftRange.upperBound)
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: lowerOffset)
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: upperOffset)
            let range = lower..<upper

            attributed[range].link = urls[n - 1]
            attributed[range].font = .system(size: 9.5, weight: .semibold, design: .monospaced)
            attributed[range].foregroundColor = Palette.textPrimary
            attributed[range].backgroundColor = Color.white.opacity(0.10)
            attributed[range].underlineStyle = nil
            attributed[range].kern = 0.4
        }
    }
}
