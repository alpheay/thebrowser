import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo = "duckduckgo"
    case brave = "brave"
    case bing = "bing"
    case google = "google"

    static let defaultValue: SearchEngine = .duckDuckGo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckDuckGo:
            return "DuckDuckGo"
        case .brave:
            return "Brave"
        case .bing:
            return "Bing"
        case .google:
            return "Google"
        }
    }

    static var selected: SearchEngine {
        let storedValue = UserDefaults.standard.string(forKey: PreferenceKey.searchEngine)
        return storedValue.flatMap(SearchEngine.init(rawValue:)) ?? defaultValue
    }

    func searchURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: queryParameterName, value: query)]
        return components.url
    }

    private var host: String {
        switch self {
        case .duckDuckGo:
            return "duckduckgo.com"
        case .brave:
            return "search.brave.com"
        case .bing:
            return "www.bing.com"
        case .google:
            return "www.google.com"
        }
    }

    private var path: String {
        switch self {
        case .duckDuckGo:
            return "/"
        case .brave, .bing, .google:
            return "/search"
        }
    }

    private var queryParameterName: String {
        "q"
    }
}
