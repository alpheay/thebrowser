import Foundation

enum NativeBrowserToolName: String, Equatable, Sendable {
    case open
    case search
    case fetch
    case readTabs = "read_tabs"
    case createArtifact = "create_artifact"
}

struct NativeBrowserToolCall: Equatable, Sendable {
    var name: NativeBrowserToolName
    var url: String? = nil
    var query: String? = nil
    var title: String? = nil
    var html: String? = nil
    var indices: [Int]? = nil

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
        case .readTabs:
            if let indices, !indices.isEmpty {
                return indices.map(String.init).joined(separator: ",")
            }
            return "all"
        case .createArtifact:
            return title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "artifact"
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
        let title = stringValue(named: "title", in: dictionary, arguments: arguments)
        let html = stringValue(named: "html", in: dictionary, arguments: arguments)
        let indices = intArrayValue(named: "indices", in: dictionary, arguments: arguments)
            ?? intArrayValue(named: "tabs", in: dictionary, arguments: arguments)

        let call = NativeBrowserToolCall(
            name: name,
            url: url,
            query: query,
            title: title,
            html: html,
            indices: indices
        )

        switch name {
        case .open, .fetch, .search:
            return call.rawInput.isEmpty ? nil : call
        case .readTabs:
            return call
        case .createArtifact:
            return (html?.isEmpty == false) ? call : nil
        }
    }

    private static func stringValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> String? {
        let raw = (dictionary[key] as? String) ?? (arguments[key] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func intArrayValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> [Int]? {
        let raw = dictionary[key] ?? arguments[key]
        guard let array = raw as? [Any] else { return nil }
        let ints: [Int] = array.compactMap { item in
            if let int = item as? Int { return int }
            if let number = item as? NSNumber { return number.intValue }
            if let string = item as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }
        return ints.isEmpty ? nil : ints
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            candidates.append(trimmed)
        }

        // Fenced tool-call block. Anchors are intentionally absent so a fence
        // can sit after prose — models often introduce the call with a
        // sentence before the fence.
        let fencePattern = #"```(?:browser_tool|json)?\s*(\{[\s\S]*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: trimmed) else { continue }
                candidates.append(String(trimmed[range]))
            }
        }

        // Trailing-JSON fallback: a balanced `{…}` whose closing brace is the
        // final non-whitespace character of the response counts as a tool
        // call. This catches the common case where the model writes a
        // sentence like "Let me open that for you." and then emits the JSON
        // on its own line. Examples embedded mid-prose are skipped because
        // the response won't end with `}`.
        if let trailing = trailingJSONObject(in: trimmed) {
            candidates.append(trailing)
        }

        return candidates.removingDuplicates()
    }

    /// Returns the substring of a complete top-level JSON object that ends
    /// the input, or `nil` if the input does not finish with one. Walks
    /// forward tracking brace depth and JSON string literals so braces
    /// inside quoted text don't confuse the balance.
    private static func trailingJSONObject(in text: String) -> String? {
        guard text.hasSuffix("}") else { return nil }

        var depth = 0
        var startIndex: String.Index? = nil
        var inString = false
        var escaped = false
        var lastCandidate: Range<String.Index>? = nil

        for index in text.indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    lastCandidate = start..<text.index(after: index)
                    startIndex = nil
                } else if depth < 0 {
                    return nil
                }
            }
        }

        guard let range = lastCandidate, range.upperBound == text.endIndex else {
            return nil
        }
        return String(text[range])
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

    /// The compact, UI-facing record of this tool call. Strips the prompt
    /// transcript and just keeps the name, raw input, and outcome — enough
    /// to render in the chat tool-chain row.
    var invocation: ChatMessage.ToolInvocation {
        ChatMessage.ToolInvocation(
            tool: call.name.rawValue,
            input: call.rawInput,
            succeeded: succeeded
        )
    }
}

struct NativeBrowserToolExecutor {
    var openURL: @MainActor (URL) -> Void
    var readTabsContent: @MainActor ([Int]?) async -> String
    var saveAndOpenArtifact: @MainActor (_ title: String, _ html: String) async throws -> URL

    func execute(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        switch call.name {
        case .open:
            return await open(call)
        case .search:
            return await search(call)
        case .fetch:
            return await fetch(call)
        case .readTabs:
            return await readTabs(call)
        case .createArtifact:
            return await createArtifact(call)
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

    private func readTabs(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let content = await readTabsContent(call.indices)
        return NativeBrowserToolResult(call: call, succeeded: true, content: content)
    }

    private func createArtifact(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let html = call.html, !html.isEmpty else {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "create_artifact requires an `html` field with the full document body.")
        }
        let title = call.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Artifact"
        do {
            let url = try await saveAndOpenArtifact(title, html)
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "Artifact saved to \(url.path) and opened in a new tab."
            )
        } catch {
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "Failed to save artifact: \(error.localizedDescription)"
            )
        }
    }
}

enum NativeBrowserToolPrompt {
    static let instructions = """
    Native browser tools available in this app:
    - open: navigates the current tab to a URL. Use for requests like "open youtube".
    - search: runs the app's native web search and returns result titles, URLs, and snippets.
    - fetch: downloads a URL and returns readable page text.
    - read_tabs: returns the visible text of the user's currently open tabs. Use this when the user asks about, summarizes across, or wants to act on the tabs they already have open. Pass `indices` (1-based) to read specific tabs, or omit it to read all of them.
    - create_artifact: saves a fully self-contained HTML document under ~/.thebrowser/web_artifacts/ and opens it in a new tab. Use this when the user asks for an "artifact", "document", "report", "dashboard", "summary", or anything similar that should be rendered as a standalone page.

    To use a tool, reply with only one JSON object and no prose:
    {"tool":"open","url":"https://example.com"}
    {"tool":"search","query":"weather in New York"}
    {"tool":"fetch","url":"https://example.com/article"}
    {"tool":"read_tabs"}
    {"tool":"read_tabs","indices":[1,3]}
    {"tool":"create_artifact","title":"Market Overview","html":"<!doctype html><html>…</html>"}

    Use a tool only when it helps the user's request. If the user asks you to open or navigate to a site, use the open tool instead of saying you will do it. If no tool is needed, answer normally. When describing your tools to the user, use words instead of tool-call JSON examples. Never say a browser action happened unless a native tool result in this conversation says it succeeded. Do not claim you can click buttons, fill forms, manage bookmarks/history/settings, or inspect hidden page state.

    create_artifact design language — every artifact MUST follow this style:
    - Background #0a0a0a, text in pure white and warm grays only. NO other colors. No blue links, no green success badges, no red warnings.
    - Inter font loaded from https://rsms.me/inter/inter.css. Display headings: weight 200–300, generous letter-spacing (-0.02em), large (40–72px). Body: weight 400, 15–17px, line-height 1.6.
    - Editorial layout: max-width ~1100px, centered, generous padding. Section dividers as 1px lines at white @ 8% opacity. Plenty of whitespace between blocks.
    - For data: use Chart.js v4 from https://cdn.jsdelivr.net/npm/chart.js. Configure all charts in monochrome — strokes/fills in white at varying opacities (0.95, 0.6, 0.3), gridlines in white @ 6%, no legend backgrounds. Disable Chart.js color defaults explicitly.
    - Animations: subtle entrance fades on load (opacity + 8px translate, 600ms ease-out, staggered). Slow shimmer or breathing pulse on hero elements is OK. NO bounce, NO playful motion, NO bright color transitions.
    - Output a SINGLE complete HTML document with inline <style> and <script>. Include <!doctype html>, <meta charset>, <meta viewport>. The `html` argument must contain the full document — not a snippet.
    - Be substantive: synthesize, compare, and visualize. Don't just dump bullet lists. The artifact should feel like a thoughtful editorial brief, not a meeting notes export.
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
