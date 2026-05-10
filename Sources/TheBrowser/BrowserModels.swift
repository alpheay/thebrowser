import Combine
import Foundation
@preconcurrency import WebKit

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()

    @Published var title: String = "New Space"
    @Published var url: URL?
    @Published var isLoading = false
    @Published var estimatedProgress = 0.0
    @Published var isHome = true
    @Published var searchPage: BrowserSearchPage?
    @Published var searchReloadToken = 0

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var searchBackStack: [BrowserSearchPage] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        super.init()

        webView.navigationDelegate = self
        observeWebView()
    }

    var displayTitle: String {
        if isHome {
            return "New Space"
        }

        if let searchPage {
            return searchPage.query
        }

        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        return url?.host(percentEncoded: false) ?? "Loading"
    }

    var displayAddress: String {
        if isHome {
            return ""
        }

        if let searchPage {
            return searchPage.query
        }

        return url?.absoluteString ?? ""
    }

    func navigate(to rawInput: String) {
        guard let destination = AddressResolver.destination(for: rawInput) else {
            return
        }

        switch destination {
        case .url(let target):
            if let searchPage {
                searchBackStack.append(searchPage)
            } else {
                searchBackStack.removeAll()
            }

            searchPage = nil
            isHome = false
            url = target
            title = target.host(percentEncoded: false) ?? target.absoluteString
            webView.load(URLRequest(url: target))
        case .search(let query):
            if let searchPage {
                searchBackStack.append(searchPage)
            } else {
                searchBackStack.removeAll()
            }

            webView.stopLoading()
            searchPage = BrowserSearchPage(query: query)
            searchReloadToken = 0
            isHome = false
            isLoading = false
            estimatedProgress = 1
            url = nil
            title = query
        }
    }

    func goHome() {
        webView.stopLoading()
        searchBackStack.removeAll()
        searchPage = nil
        isHome = true
        isLoading = false
        estimatedProgress = 0
        title = "New Space"
        url = nil
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else if let previousSearchPage = searchBackStack.popLast() {
            webView.stopLoading()
            searchPage = previousSearchPage
            isHome = false
            isLoading = false
            estimatedProgress = 1
            url = nil
            title = previousSearchPage.query
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func reload() {
        if isHome {
            return
        }

        if searchPage != nil {
            searchReloadToken &+= 1
            return
        }

        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
        isLoading = false
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let title = webView.title, !title.isEmpty {
                        self.title = title
                    }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let url = webView.url {
                        self.url = url
                    }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.isLoading = webView.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.estimatedProgress = webView.estimatedProgress
                }
            }
        ]
    }
}

extension BrowserTab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.isHome = false
            self.isLoading = true
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.estimatedProgress = 1
            self.url = webView.url
            if let title = webView.title, !title.isEmpty {
                self.title = title
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
        }
    }
}

enum AddressResolver {
    static func destination(for input: String) -> AddressDestination? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return .url(url)
        }

        if looksLikeLocalAddress(trimmed), let url = URL(string: "http://\(trimmed)") {
            return .url(url)
        }

        if looksLikeDomain(trimmed), let url = URL(string: "https://\(trimmed)") {
            return .url(url)
        }

        return .search(trimmed)
    }

    static func url(for input: String) -> URL? {
        switch destination(for: input) {
        case .url(let url):
            return url
        case .search(let query):
            return SearchEngine.selected.searchURL(for: query)
        case nil:
            return nil
        }
    }

    private static func looksLikeDomain(_ value: String) -> Bool {
        value.contains(".") && !containsWhitespace(value)
    }

    private static func looksLikeLocalAddress(_ value: String) -> Bool {
        let lowercasedValue = value.lowercased()
        return (lowercasedValue == "localhost" || lowercasedValue.hasPrefix("localhost:") || lowercasedValue.hasPrefix("localhost/")) && !containsWhitespace(value)
    }

    private static func containsWhitespace(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }
}

enum AddressDestination {
    case url(URL)
    case search(String)
}

struct BrowserSearchPage: Equatable, Identifiable {
    let id = UUID()
    var query: String
}

struct BrowserPageContext: Sendable {
    var title: String
    var url: String
}
