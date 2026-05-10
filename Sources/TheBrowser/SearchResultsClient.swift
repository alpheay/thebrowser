import Foundation

struct SearchResponse: Equatable {
    var providerName: String
    var results: [SearchResult]
    var instantAnswer: SearchInstantAnswer?
}

struct SearchResult: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var url: URL
    var snippet: String

    var displayURL: String {
        guard let host = url.host(percentEncoded: false) else {
            return url.absoluteString
        }

        let path = url.path(percentEncoded: false)
        if path.isEmpty || path == "/" {
            return host
        }

        return host + path
    }
}

struct SearchInstantAnswer: Equatable {
    var title: String
    var text: String
    var url: URL?
    var source: String
}

enum SearchResultsClient {
    static func search(query: String) async throws -> SearchResponse {
        do {
            let results = try await BraveSearchClient.search(query: query)
            if !results.isEmpty {
                return SearchResponse(providerName: "Brave", results: results, instantAnswer: nil)
            }
        } catch {
            let fallback = try await DuckDuckGoInstantAnswerClient.search(query: query)
            return fallback
        }

        return try await DuckDuckGoInstantAnswerClient.search(query: query)
    }
}

private enum BraveSearchClient {
    static func search(query: String) async throws -> [SearchResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "search.brave.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "source", value: "web")
        ]

        guard let url = components.url else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            return []
        }

        guard let html = String(data: data, encoding: .utf8) else {
            return []
        }

        return BraveSearchParser.parse(html: html)
    }
}

private enum DuckDuckGoInstantAnswerClient {
    static func search(query: String) async throws -> SearchResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.duckduckgo.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components.url else {
            return SearchResponse(providerName: "DuckDuckGo", results: [], instantAnswer: nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            return SearchResponse(providerName: "DuckDuckGo", results: [], instantAnswer: nil)
        }

        let payload = try JSONDecoder().decode(DuckDuckGoPayload.self, from: data)
        return SearchResponse(
            providerName: "DuckDuckGo",
            results: payload.results,
            instantAnswer: payload.instantAnswer
        )
    }
}

private enum BraveSearchParser {
    static func parse(html: String) -> [SearchResult] {
        let pattern = #"<div class=\"snippet[^\"]*\"[^>]*data-pos=\"\d+\"[^>]*data-type=\"web\".*?<a href=\"([^\"]+)\"[^>]*class=\"[^\"]*\bl1\b[^\"]*\".*?<div class=\"title[^\"]*\" title=\"([^\"]*)\">(.*?)</div>.*?<div class=\"content[^\"]*\">(.*?)</div>"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let matches = regex?.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)) ?? []
        var seenURLs = Set<String>()
        var results: [SearchResult] = []

        for match in matches {
            guard
                let rawURL = html.substring(for: match.range(at: 1))?.htmlDecoded,
                let url = URL(string: rawURL),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                continue
            }

            let urlKey = url.absoluteString
            guard !seenURLs.contains(urlKey) else {
                continue
            }

            let titleAttribute = html.substring(for: match.range(at: 2))?.htmlDecoded.cleanedHTMLText ?? ""
            let titleMarkup = html.substring(for: match.range(at: 3))?.cleanedHTMLText ?? ""
            let snippetMarkup = html.substring(for: match.range(at: 4))?.cleanedHTMLText ?? ""
            let title = titleAttribute.isEmpty ? titleMarkup : titleAttribute

            guard !title.isEmpty else {
                continue
            }

            seenURLs.insert(urlKey)
            results.append(SearchResult(title: title, url: url, snippet: snippetMarkup))

            if results.count >= 12 {
                break
            }
        }

        return results
    }
}

private struct DuckDuckGoPayload: Decodable {
    var heading: String
    var abstractText: String
    var abstractURL: String
    var abstractSource: String
    var resultsPayload: [DuckDuckGoTopic]
    var relatedTopics: [DuckDuckGoTopic]

    enum CodingKeys: String, CodingKey {
        case heading = "Heading"
        case abstractText = "AbstractText"
        case abstractURL = "AbstractURL"
        case abstractSource = "AbstractSource"
        case resultsPayload = "Results"
        case relatedTopics = "RelatedTopics"
    }

    var instantAnswer: SearchInstantAnswer? {
        guard !abstractText.isEmpty else {
            return nil
        }

        return SearchInstantAnswer(
            title: heading.isEmpty ? abstractSource : heading,
            text: abstractText,
            url: URL(string: abstractURL),
            source: abstractSource.isEmpty ? "DuckDuckGo" : abstractSource
        )
    }

    var results: [SearchResult] {
        var output: [SearchResult] = []
        output.append(contentsOf: resultsPayload.searchResults)
        output.append(contentsOf: relatedTopics.searchResults)
        return Array(output.prefix(10))
    }
}

private struct DuckDuckGoTopic: Decodable {
    var firstURL: String?
    var text: String?
    var topics: [DuckDuckGoTopic]?

    enum CodingKeys: String, CodingKey {
        case firstURL = "FirstURL"
        case text = "Text"
        case topics = "Topics"
    }
}

private extension Array where Element == DuckDuckGoTopic {
    var searchResults: [SearchResult] {
        flatMap { topic -> [SearchResult] in
            if let topics = topic.topics {
                return topics.searchResults
            }

            guard
                let firstURL = topic.firstURL,
                let url = URL(string: firstURL),
                let text = topic.text,
                !text.isEmpty
            else {
                return []
            }

            let parts = text.components(separatedBy: " - ")
            let title = parts.first ?? text
            let snippet = parts.dropFirst().joined(separator: " - ")
            return [SearchResult(title: title, url: url, snippet: snippet)]
        }
    }
}

private extension String {
    func substring(for range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else {
            return nil
        }

        return String(self[swiftRange])
    }

    var cleanedHTMLText: String {
        var output = replacingOccurrences(of: #"<!--.*?-->"#, with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        output = output.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        output = output.htmlDecoded
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var htmlDecoded: String {
        var output = self
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

        for (entity, value) in namedEntities {
            output = output.replacingOccurrences(of: entity, with: value)
        }

        output = output.replacingNumericEntities(pattern: #"&#x([0-9A-Fa-f]+);"#, radix: 16)
        output = output.replacingNumericEntities(pattern: #"&#([0-9]+);"#, radix: 10)
        return output
    }

    private func replacingNumericEntities(pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        var output = self
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
