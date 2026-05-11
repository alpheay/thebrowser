import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func fetch(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
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
