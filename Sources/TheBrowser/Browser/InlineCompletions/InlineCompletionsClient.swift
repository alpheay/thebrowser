import Foundation

/// One-shot fast-model call for an inline completion. Builds a compact
/// prompt from the JS-supplied payload, forces the provider's fast model,
/// and post-processes the response so the UI only ever sees a single
/// short continuation (no preambles, no quoted echoes, no duplicates of
/// what the user already typed).
enum InlineCompletionsClient {
    struct Request: Sendable {
        var host: String
        var pageTitle: String
        var elementKind: String
        var elementLabel: String
        var nearestHeading: String
        var siteHints: [String: String]
        var textBefore: String
        var textAfter: String
        var redactionApplied: Bool
    }

    static func complete(_ request: Request) async throws -> String? {
        let configuration = AIHarnessConfiguration.current()
        let fastModel = configuration.provider.fastModelID
        let prompt = formatPrompt(request)
        let response = try await AIProviderClient().ask(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            modelOverride: fastModel
        )
        return sanitize(response: response, request: request)
    }

    private static func formatPrompt(_ r: Request) -> String {
        var lines: [String] = []

        let titleTrim = r.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = r.host.isEmpty ? "unknown" : r.host
        let kindLabel = r.elementKind == "contenteditable" ? "rich-text editor" : "textarea"
        let labelTrim = r.elementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingTrim = r.nearestHeading.trimmingCharacters(in: .whitespacesAndNewlines)

        lines.append("Site: \(host)\(titleTrim.isEmpty ? "" : " — \"\(truncate(titleTrim, 120))\"")")
        if labelTrim.isEmpty {
            lines.append("Element: \(kindLabel)")
        } else {
            lines.append("Element: \(kindLabel) (\(truncate(labelTrim, 80)))")
        }
        if !headingTrim.isEmpty {
            lines.append("Nearest heading: \(truncate(headingTrim, 120))")
        }
        if !r.siteHints.isEmpty {
            lines.append("Context hints:")
            for key in r.siteHints.keys.sorted() {
                let value = r.siteHints[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty {
                    lines.append("  \(key): \(truncate(value, 280))")
                }
            }
        }
        if r.redactionApplied {
            lines.append("Note: [REDACTED] placeholders mark text where likely secrets were stripped.")
        }
        lines.append("")
        lines.append("Text before cursor:")
        lines.append("\"\"\"")
        lines.append(r.textBefore)
        lines.append("\"\"\"")
        if !r.textAfter.isEmpty {
            lines.append("")
            lines.append("Text after cursor (do not duplicate any of it):")
            lines.append("\"\"\"")
            lines.append(r.textAfter)
            lines.append("\"\"\"")
        }
        lines.append("")
        lines.append("Continuation:")
        return lines.joined(separator: "\n")
    }

    /// Trim wrapper quotes / preamble / multi-line spillover, and bail if
    /// the model echoed the tail of the user's prefix — better to show
    /// nothing than insert a duplicated chunk on Tab.
    private static func sanitize(response: String, request: Request) -> String? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.startIndex..<newline])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 200 {
            if let end = text.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
                let upTo = text.index(after: end)
                text = String(text[text.startIndex..<upTo])
            } else {
                text = String(text.prefix(200))
            }
        }

        if echoesPrefix(text: text, prefix: request.textBefore) {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    /// Cheap echo detector: if the start of the model's reply looks like
    /// the end of the user's prefix, we treat the suggestion as a useless
    /// duplicate.
    private static func echoesPrefix(text: String, prefix: String) -> Bool {
        guard !text.isEmpty, !prefix.isEmpty else { return false }
        let headLength = min(text.count, 16)
        let head = String(text.prefix(headLength)).lowercased()
        let tailLength = min(prefix.count, 60)
        let tail = String(prefix.suffix(tailLength)).lowercased()
        return tail.hasSuffix(head)
    }

    private static func truncate(_ value: String, _ limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[value.startIndex..<end]) + "…"
    }

    static let systemPrompt = """
    You are an inline writing autocomplete. Given the text the user has typed, output a short continuation (at most one sentence, at most 12 words) that the user would naturally type next.

    Output ONLY the continuation text — no preamble, no quotes, no formatting.
    If the cursor is mid-word, finish that word first.
    If there is nothing useful to add, output an empty string.
    Never repeat any of the user's existing text.
    Match the tone of the surrounding text (formal, casual, technical) and the site context provided.
    """
}
