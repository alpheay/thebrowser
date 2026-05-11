import Foundation

/// One fetched preview. Either a fully populated `.ready` (body text + meta
/// description) or a slim fallback (`title` + `description` only) plus a
/// reason field so the panel can render a useful placeholder.
struct HoverPreviewContent: Equatable, Sendable {
    var url: URL
    var finalURL: URL
    var title: String
    var description: String
    var bodyText: String
    var faviconURL: URL?
    var wordCount: Int
}

enum HoverPreviewFetchError: LocalizedError, Equatable {
    case authRequired(status: Int)
    case unavailable(reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authRequired:
            return "Preview unavailable — this page requires sign-in."
        case .unavailable(let reason):
            return "Preview unavailable — \(reason)"
        case .cancelled:
            return "Preview cancelled."
        }
    }
}

/// HTTP-only off-screen fetcher. Never spins up a WKWebView — reads the raw
/// HTML, strips it to readable text, and pulls out title + description +
/// favicon. Reuses the strategy from
/// [FetchTool.swift](../../Chat/NativeBrowserTools/FetchTool.swift) but with
/// extra metadata fields that the panel needs.
enum HoverPreviewFetcher {
    static let bodyByteLimit = 24_000
    static let requestTimeout: TimeInterval = 8
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    static func fetch(url: URL) async throws -> HoverPreviewContent {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw HoverPreviewFetchError.unavailable(reason: "unsupported scheme")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw HoverPreviewFetchError.cancelled
        } catch {
            throw HoverPreviewFetchError.unavailable(reason: error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 401 || status == 403 {
            throw HoverPreviewFetchError.authRequired(status: status)
        }
        if status > 0, !(200..<400).contains(status) {
            throw HoverPreviewFetchError.unavailable(reason: "HTTP \(status)")
        }

        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let finalURL = response.url ?? url

        // Non-HTML payloads (PDFs, plain text, images) still get a slim card
        // — title is the filename, body is the raw bytes' first lines.
        if !contentType.isEmpty,
           !contentType.contains("html"),
           !contentType.contains("xml") {
            let raw = String(data: data.prefix(8_000), encoding: .utf8)
                ?? String(data: data.prefix(8_000), encoding: .isoLatin1)
                ?? ""
            let body = HoverPreviewExtractor.collapsedWhitespace(raw)
            return HoverPreviewContent(
                url: url,
                finalURL: finalURL,
                title: finalURL.lastPathComponent,
                description: "",
                bodyText: body,
                faviconURL: HoverPreviewExtractor.faviconURL(for: finalURL, parsed: nil),
                wordCount: HoverPreviewExtractor.wordCount(body)
            )
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let parsed = HoverPreviewExtractor.parse(html: html, sourceURL: finalURL)
        return HoverPreviewContent(
            url: url,
            finalURL: finalURL,
            title: parsed.title,
            description: parsed.description,
            bodyText: parsed.body,
            faviconURL: parsed.faviconURL ?? HoverPreviewExtractor.faviconURL(for: finalURL, parsed: parsed),
            wordCount: parsed.wordCount
        )
    }
}

/// Stateless HTML parser tuned for "give me enough metadata for a link
/// preview without going full Readability." Pulls `<title>`, the canonical
/// description meta tags, an icon link if one is declared, and a stripped
/// readable body capped at ``HoverPreviewFetcher.bodyByteLimit``.
enum HoverPreviewExtractor {
    struct Parsed {
        var title: String
        var description: String
        var body: String
        var faviconURL: URL?
        var wordCount: Int
    }

    static func parse(html: String, sourceURL: URL) -> Parsed {
        let title = extractTitle(from: html)
        let description = extractDescription(from: html)
        let favicon = extractFavicon(from: html, baseURL: sourceURL)
        let body = extractBody(from: html, byteLimit: HoverPreviewFetcher.bodyByteLimit)
        return Parsed(
            title: title.isEmpty ? sourceURL.host ?? sourceURL.absoluteString : title,
            description: description,
            body: body,
            faviconURL: favicon,
            wordCount: wordCount(body)
        )
    }

    // MARK: - Title / description / favicon

    private static func extractTitle(from html: String) -> String {
        if let raw = firstMatch(in: html, pattern: #"(?is)<title[^>]*>(.*?)</title>"#, group: 1) {
            return htmlDecoded(stripTags(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let og = metaContent(in: html, name: "og:title", isProperty: true) {
            return og
        }
        return ""
    }

    private static func extractDescription(from html: String) -> String {
        if let og = metaContent(in: html, name: "og:description", isProperty: true) {
            return og
        }
        if let twitter = metaContent(in: html, name: "twitter:description", isProperty: false) {
            return twitter
        }
        if let meta = metaContent(in: html, name: "description", isProperty: false) {
            return meta
        }
        return ""
    }

    private static func extractFavicon(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            #"(?is)<link[^>]+rel\s*=\s*['"]?(?:shortcut\s+)?icon['"]?[^>]*href\s*=\s*['"]([^'"]+)['"]"#,
            #"(?is)<link[^>]+href\s*=\s*['"]([^'"]+)['"][^>]+rel\s*=\s*['"]?(?:shortcut\s+)?icon['"]?"#,
            #"(?is)<link[^>]+rel\s*=\s*['"]apple-touch-icon['"][^>]*href\s*=\s*['"]([^'"]+)['"]"#
        ]
        for pattern in patterns {
            if let href = firstMatch(in: html, pattern: pattern, group: 1) {
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                    return url
                }
            }
        }
        return nil
    }

    /// Last-ditch favicon — Google's favicon proxy. Used when the page
    /// didn't declare its own. Mirrors ``FaviconView`` in BrowserToolbar.
    static func faviconURL(for url: URL, parsed: Parsed?) -> URL? {
        if let parsed, let declared = parsed.faviconURL { return declared }
        guard let host = url.host(percentEncoded: false) else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }

    // MARK: - Body text

    private static func extractBody(from html: String, byteLimit: Int) -> String {
        var stripped = html
        stripped = stripped.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<style\b[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<noscript\b[^>]*>.*?</noscript>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<head\b[^>]*>.*?</head>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<nav\b[^>]*>.*?</nav>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<footer\b[^>]*>.*?</footer>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?is)<aside\b[^>]*>.*?</aside>"#, with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"(?i)</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = htmlDecoded(stripped)
        let collapsed = collapsedWhitespace(decoded)
        if collapsed.utf8.count <= byteLimit {
            return collapsed
        }
        return String(collapsed.prefix(byteLimit)) + "\n…[truncated]"
    }

    static func collapsedWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    // MARK: - Helpers

    private static func metaContent(in html: String, name: String, isProperty: Bool) -> String? {
        let attr = isProperty ? "property" : "name"
        let patterns = [
            #"(?is)<meta[^>]+"# + attr + #"\s*=\s*['"]"# + NSRegularExpression.escapedPattern(for: name) + #"['"][^>]*content\s*=\s*['"]([^'"]*)['"]"#,
            #"(?is)<meta[^>]+content\s*=\s*['"]([^'"]*)['"][^>]+"# + attr + #"\s*=\s*['"]"# + NSRegularExpression.escapedPattern(for: name) + #"['"]"#
        ]
        for pattern in patterns {
            if let value = firstMatch(in: html, pattern: pattern, group: 1) {
                let decoded = htmlDecoded(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    private static func firstMatch(in input: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              match.numberOfRanges > group,
              let captured = Range(match.range(at: group), in: input) else {
            return nil
        }
        return String(input[captured])
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
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
            "&nbsp;": " ",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
            "&laquo;": "«",
            "&raquo;": "»",
            "&copy;": "©",
            "&reg;": "®"
        ]
        for (entity, replacement) in namedEntities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        output = replacingNumericEntities(in: output, pattern: #"&#x([0-9A-Fa-f]+);"#, radix: 16)
        output = replacingNumericEntities(in: output, pattern: #"&#([0-9]+);"#, radix: 10)
        return output
    }

    private static func replacingNumericEntities(in value: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        var output = value
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output))
        for match in matches.reversed() {
            guard let entityRange = Range(match.range(at: 0), in: output),
                  let numberRange = Range(match.range(at: 1), in: output),
                  let scalar = UInt32(output[numberRange], radix: radix).flatMap(UnicodeScalar.init) else {
                continue
            }
            output.replaceSubrange(entityRange, with: String(Character(scalar)))
        }
        return output
    }
}
