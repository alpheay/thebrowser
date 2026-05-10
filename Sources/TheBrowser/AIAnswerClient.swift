import Foundation

/// Generates an inline AI answer above search results when the query reads
/// as a question. The answer is grounded in the visible search results so
/// citations like "[1]" point to specific URLs the user can click.
enum AIAnswerClient {
    /// Maximum number of search results passed to the model as evidence.
    /// Top hits carry most of the signal; trimming the long tail keeps the
    /// prompt small and the response focused.
    private static let maxSources = 6

    static func answer(question: String, results: [SearchResult]) async throws -> String {
        let sources = Array(results.prefix(maxSources))
        guard !sources.isEmpty else {
            throw AIAnswerError.noSources
        }

        let prompt = formatPrompt(question: question, sources: sources)
        let provider = AIHarnessConfiguration.current().provider
        let response = try await AIProviderClient().ask(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            modelOverride: provider.fastModelID
        )

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AIAnswerError.emptyResponse
        }
        return cleaned
    }

    /// Sources passed to the model in the same order as the array, so [1]
    /// refers to `sources[0]` when rendering citation links.
    static func citationURLs(for results: [SearchResult]) -> [URL] {
        Array(results.prefix(maxSources)).map(\.url)
    }

    static func formatPrompt(question: String, sources: [SearchResult]) -> String {
        var lines: [String] = []
        lines.append("You are answering a user's web search query. Use ONLY the numbered sources below as evidence; do not introduce facts they do not support. Cite inline with bracketed indices like [1] or [2] (matching the source numbers) right after the claim each one supports. Multiple citations: write \"[1][2]\" — never combine into [1, 2].")
        lines.append("")
        lines.append("Style:")
        lines.append("- Markdown formatting. Short paragraphs, **bold** for key terms, bullet lists when listing.")
        lines.append("- Lead with the answer. No preambles like \"Based on the sources\" or \"Here is\".")
        lines.append("- Stay under ~140 words.")
        lines.append("- If sources disagree, briefly note the disagreement.")
        lines.append("- If sources do not actually answer the question, say so plainly in one sentence and stop.")
        lines.append("- Do not include a trailing \"Sources:\" section — citations alone suffice.")
        lines.append("")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Sources:")
        for (idx, source) in sources.enumerated() {
            let n = idx + 1
            lines.append("[\(n)] \(source.title) — \(source.url.absoluteString)")
            let snippet = source.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                lines.append("    \(snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Replace the user's persistent chat persona for this one-shot call so
    /// custom personas (e.g. "answer in haiku") don't break citation format.
    private static let systemPrompt = """
    You are an assistant that produces concise, factual answers grounded in provided web sources. Always preserve inline citations exactly as instructed in the user prompt. Never invent facts or sources. Avoid emojis.
    """
}

enum AIAnswerError: LocalizedError {
    case noSources
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "No search results to ground the answer in."
        case .emptyResponse:
            return "The AI provider returned an empty response."
        }
    }
}
