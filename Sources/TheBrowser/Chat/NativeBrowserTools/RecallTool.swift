import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:). Searches the user's local
    /// Recall index and formats the ranked passages as citations for the model
    /// to synthesize from. Retrieval is entirely on-device; only the passages
    /// surfaced here (the ones answering the question) reach the model.
    func recall(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let query = call.rawInput
        let limit = min(max(call.maxResults ?? 8, 1), 20)
        let hits = await searchHistory(query, call.sinceDays, limit)
        return NativeBrowserToolResult(
            call: call,
            succeeded: true,
            content: RecallToolFormatter.format(query: query, hits: hits)
        )
    }
}

private enum RecallToolFormatter {
    static func format(query: String, hits: [RecallHit]) -> String {
        let label = query.isEmpty ? "that time range" : "\"\(query)\""
        guard !hits.isEmpty else {
            return """
            No strong match in the user's local history for \(label). Tell the \
            user you don't have that in their history rather than guessing — and \
            offer to search the web instead if useful.
            """
        }

        var lines: [String] = [
            "Found \(hits.count) page(s) in the user's local browsing history " +
            "matching \(label). These are passages from pages the user actually " +
            "read. Answer from them, cite the title + URL, and offer to reopen " +
            "the page. Do not invent details beyond these passages."
        ]
        for (index, hit) in hits.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(hit.displayTitle)")
            lines.append("URL: \(hit.url.absoluteString)")
            var meta = "Last read: \(relativeDate(hit.lastVisitedAt))"
            if hit.visitCount > 1 { meta += " · read \(hit.visitCount)×" }
            if hit.starred { meta += " · starred" }
            lines.append(meta)
            if let heading = hit.heading, !heading.isEmpty {
                lines.append("Section: \(heading)")
            }
            lines.append("Passage: \(hit.snippet)")
        }
        return lines.joined(separator: "\n")
    }

    static func relativeDate(_ date: Date) -> String {
        guard date > .distantPast else { return "unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
