import Foundation

enum NativeBrowserToolName: String, Equatable, Sendable {
    case open
    case search
    case fetch
}

struct NativeBrowserToolCall: Equatable, Sendable {
    var name: NativeBrowserToolName
    var url: String?
    var query: String?

    static func parse(from text: String) -> NativeBrowserToolCall? {
        for candidate in jsonObjectCandidates(in: text) {
            if let call = parse(json: candidate) {
                return call
            }
        }
        return nil
    }

    var rawInput: String {
        switch name {
        case .open, .fetch:
            return url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .search:
            return query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private static func parse(json: String) -> NativeBrowserToolCall? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let arguments = dictionary["arguments"] as? [String: Any] ?? [:]
        let rawName = (dictionary["tool"] as? String)
            ?? (dictionary["name"] as? String)
            ?? (dictionary["action"] as? String)

        guard
            let rawName,
            let name = NativeBrowserToolName(rawValue: rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return nil
        }

        let url = stringValue(named: "url", in: dictionary, arguments: arguments)
            ?? stringValue(named: "target", in: dictionary, arguments: arguments)
        let query = stringValue(named: "query", in: dictionary, arguments: arguments)
            ?? stringValue(named: "q", in: dictionary, arguments: arguments)

        let call = NativeBrowserToolCall(name: name, url: url, query: query)
        return call.rawInput.isEmpty ? nil : call
    }

    private static func stringValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> String? {
        let raw = (dictionary[key] as? String) ?? (arguments[key] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            candidates.append(trimmed)
        }

        let pattern = #"^```(?:browser_tool|json)?\s*(\{[\s\S]*\})\s*```$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: trimmed) else { continue }
                candidates.append(String(trimmed[range]))
            }
        }

        return candidates.removingDuplicates()
    }
}

struct NativeBrowserToolResult: Equatable, Sendable {
    var call: NativeBrowserToolCall
    var succeeded: Bool
    var content: String

    var promptText: String {
        """
        Tool: \(call.name.rawValue)
        Status: \(succeeded ? "success" : "failed")
        \(content)
        """
    }
}

struct NativeBrowserToolExecutor {
    var openURL: @MainActor (URL) -> Void

    func execute(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        switch call.name {
        case .open:
            return await open(call)
        case .search:
            return await search(call)
        case .fetch:
            return await fetch(call)
        }
    }

    private func open(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let url = NativeBrowserToolURL.url(from: call.rawInput) else {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Invalid URL: \(call.rawInput)")
        }

        await MainActor.run {
            openURL(url)
        }

        return NativeBrowserToolResult(call: call, succeeded: true, content: "Opened \(url.absoluteString) in the current tab.")
    }

    private func search(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
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

    private func fetch(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let url = NativeBrowserToolURL.url(from: call.rawInput) else {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Invalid URL: \(call.rawInput)")
        }

        do {
            let page = try await NativeBrowserFetcher.fetch(url: url)
            return NativeBrowserToolResult(call: call, succeeded: true, content: page)
        } catch {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Fetch failed for \(url.absoluteString): \(error.localizedDescription)")
        }
    }
}

enum NativeBrowserToolPrompt {
    static let instructions = """
    Native browser tools available in this app:
    - open: navigates the current tab to a URL. Use for requests like "open youtube".
    - search: runs the app's native web search and returns result titles, URLs, and snippets.
    - fetch: downloads a URL and returns readable page text.

    To use a tool, reply with only one JSON object and no prose:
    {"tool":"open","url":"https://example.com"}
    {"tool":"search","query":"weather in New York"}
    {"tool":"fetch","url":"https://example.com/article"}

    Use a tool only when it helps the user's request. If the user asks you to open or navigate to a site, use the open tool instead of saying you will do it. If no tool is needed, answer normally. When describing your tools to the user, use words instead of tool-call JSON examples. Never say a browser action happened unless a native tool result in this conversation says it succeeded. Do not claim you can click buttons, fill forms, manage bookmarks/history/settings, or inspect hidden page state.
    """

    static func continuationPrompt(basePrompt: String, results: [NativeBrowserToolResult]) -> String {
        let transcript = results.enumerated().map { index, result in
            """
            Native browser tool result \(index + 1):
            \(result.promptText)
            """
        }.joined(separator: "\n\n")

        return """
        \(basePrompt)

        \(transcript)

        Use the native browser tool result to continue the same user request. If one more native browser tool is required, reply with only the next JSON tool call. Otherwise, answer normally and briefly. Do not claim any browser action succeeded unless the tool result says success.
        """
    }
}

private enum NativeBrowserToolURL {
    static func url(from rawValue: String) -> URL? {
        guard let url = AddressResolver.url(for: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            return nil
        }
        return url
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

private enum NativeBrowserFetcher {
    static func fetch(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw NativeBrowserFetchError.badStatus(httpResponse.statusCode)
        }

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let text = NativeBrowserFetchText.text(from: raw, contentType: contentType)
        guard !text.isEmpty else {
            throw NativeBrowserFetchError.emptyText
        }

        return """
        URL: \(url.absoluteString)
        Content type: \(contentType.isEmpty ? "unknown" : contentType)
        Text:
        \(String(text.prefix(8_000)))
        """
    }
}

private enum NativeBrowserFetchError: LocalizedError {
    case badStatus(Int)
    case emptyText

    var errorDescription: String? {
        switch self {
        case .badStatus(let status):
            return "HTTP \(status)"
        case .emptyText:
            return "No readable text was found."
        }
    }
}

private enum NativeBrowserFetchText {
    static func text(from raw: String, contentType: String) -> String {
        if contentType.localizedCaseInsensitiveContains("html") || raw.localizedCaseInsensitiveContains("<html") {
            return htmlText(from: raw)
        }

        return collapsedWhitespace(raw)
    }

    private static func htmlText(from html: String) -> String {
        var output = html
        output = output.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?is)<style\b[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?is)<noscript\b[^>]*>.*?</noscript>"#, with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?i)</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
        output = output.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return collapsedWhitespace(htmlDecoded(output))
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlDecoded(_ value: String) -> String {
        var output = value
        let namedEntities = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#x27;": "'",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]

        for (entity, replacement) in namedEntities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }

        output = replacingNumericEntities(in: output, pattern: #"&#x([0-9A-Fa-f]+);"#, radix: 16)
        output = replacingNumericEntities(in: output, pattern: #"&#([0-9]+);"#, radix: 10)
        return output
    }

    private static func replacingNumericEntities(in value: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        var output = value
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output))

        for match in matches.reversed() {
            guard
                let entityRange = Range(match.range(at: 0), in: output),
                let numberRange = Range(match.range(at: 1), in: output),
                let value = UInt32(output[numberRange], radix: radix),
                let scalar = UnicodeScalar(value)
            else {
                continue
            }

            output.replaceSubrange(entityRange, with: String(Character(scalar)))
        }

        return output
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
