import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func search(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let query = call.rawInput
        do {
            let response = try await SearchResultsClient.search(query: query)
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: NativeBrowserToolFormatter.searchResults(response, query: query)
            )
        } catch {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Search failed: \(error.localizedDescription)")
        }
    }
}

private enum NativeBrowserToolFormatter {
    static func searchResults(_ response: SearchResponse, query: String) -> String {
        var lines: [String] = []
        lines.append("Query: \(query)")
        lines.append("Provider: \(response.providerName)")

        if let answer = response.instantAnswer {
            lines.append("")
            lines.append("Instant answer: \(answer.title)")
            lines.append(answer.text)
            if let url = answer.url {
                lines.append("URL: \(url.absoluteString)")
            }
        }

        let results = Array(response.results.prefix(6))
        if results.isEmpty {
            lines.append("")
            lines.append("No search results found.")
        } else {
            lines.append("")
            lines.append("Results:")
            for (index, result) in results.enumerated() {
                lines.append("\(index + 1). \(result.title)")
                lines.append("URL: \(result.url.absoluteString)")
                if !result.snippet.isEmpty {
                    lines.append("Snippet: \(result.snippet)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
