import Foundation

/// Single-shot LLM call that turns a natural-language query
/// ("where retry semantics are discussed") into a verbatim substring of the
/// current page that WKWebView's native find can highlight.
///
/// The contract with the model is narrow on purpose: it must return a chunk
/// of text that appears *verbatim* in the page, otherwise the handoff to
/// ``WKWebView/find(_:configuration:completionHandler:)`` produces nothing.
/// We keep prompts small and use each provider's ``fastModelID`` so the
/// round trip stays under a second on typical pages.
enum ConversationalFindClient {
    /// Page text past this point is dropped before the LLM call. Haiku 4.5 and
    /// GPT-5.4-mini both handle far more, but speed matters here and the bulk
    /// of articles fit comfortably; very long pages get a head-truncation.
    private static let maxPageTextChars = 60_000

    /// Sentinel string the model returns when nothing on the page matches.
    static let noMatchSentinel = "NO_MATCH"

    enum Result {
        case phrase(String)
        case noMatch
    }

    static func resolve(question: String, pageText: String) async throws -> Result {
        let trimmedPage = truncatedPageText(pageText)
        guard !trimmedPage.isEmpty else {
            throw ConversationalFindError.emptyPage
        }

        let prompt = formatPrompt(question: question, pageText: trimmedPage)
        let provider = AIHarnessConfiguration.current().provider
        let response = try await AIProviderClient().ask(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            modelOverride: provider.fastModelID
        )

        let cleaned = sanitize(response)
        guard !cleaned.isEmpty else {
            throw ConversationalFindError.emptyResponse
        }
        if cleaned.caseInsensitiveCompare(noMatchSentinel) == .orderedSame {
            return .noMatch
        }
        return .phrase(cleaned)
    }

    /// Strips quotes, code fences, leading labels (`Phrase:`), and trailing
    /// punctuation that small models sometimes append even when told not to.
    /// Conservative on purpose — anything that survives must appear verbatim
    /// in the page or the downstream `WKWebView.find` will report no match.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let end = text.range(of: "```", options: .backwards), end.lowerBound > text.startIndex {
                let body = text[text.index(after: text.startIndex)...]
                if let openEnd = body.firstIndex(of: "\n") {
                    let inner = body[body.index(after: openEnd)..<text.index(end.lowerBound, offsetBy: -1)]
                    text = String(inner)
                }
            }
            text = text.replacingOccurrences(of: "```", with: "")
        }
        if let colon = text.firstIndex(of: ":") {
            let label = text[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            // Only strip prefixes that match a known meta-label. A loose
            // "any short word followed by a colon" rule would also eat real
            // page substrings like "see also: retry policy" or "Step 3:".
            let labelVocabulary: Set<String> = [
                "phrase", "answer", "result", "snippet", "match", "text", "output", "passage", "quote"
            ]
            if labelVocabulary.contains(label) {
                text = String(text[text.index(after: colon)...])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "'", "\u{2018}", "\u{2019}"]
        while let first = text.first, quoteChars.contains(first) {
            text.removeFirst()
        }
        while let last = text.last, quoteChars.contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatedPageText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxPageTextChars { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxPageTextChars)
        return String(trimmed[..<endIndex])
    }

    static func formatPrompt(question: String, pageText: String) -> String {
        """
        The user is searching a web page conversationally. Their query is:
        \(question)

        Below is the visible text of the page. Find the single passage that best matches what the user is asking about. Return ONLY a verbatim substring of the page text — between 3 and 12 words — that uniquely identifies the matching passage so a literal text search can jump to it.

        Rules:
        - The returned phrase MUST appear verbatim (same characters, same order, same casing) somewhere in the page text.
        - Do not paraphrase, summarize, translate, or fix typos.
        - Do not wrap the phrase in quotes, code fences, or markdown.
        - Do not prefix the response with labels like "Phrase:" or "Answer:".
        - If nothing on the page matches the user's query, respond with exactly: \(noMatchSentinel)

        Page text:
        \"\"\"
        \(pageText)
        \"\"\"
        """
    }

    private static let systemPrompt = """
    You locate passages in web page text on behalf of a conversational find feature. You always return a verbatim substring of the supplied page text, or the literal token NO_MATCH. You never paraphrase, never add commentary, and never wrap the phrase in quotes or markdown.
    """
}

enum ConversationalFindError: LocalizedError {
    case emptyPage
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyPage:
            return "This page has no text to search."
        case .emptyResponse:
            return "The AI provider returned an empty response."
        }
    }
}
