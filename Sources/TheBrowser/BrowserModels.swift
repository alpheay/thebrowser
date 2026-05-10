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

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

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

        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        return url?.host(percentEncoded: false) ?? "Loading"
    }

    var displayAddress: String {
        if isHome {
            return ""
        }

        return url?.absoluteString ?? ""
    }

    func navigate(to rawInput: String) {
        guard let target = AddressResolver.url(for: rawInput) else {
            return
        }

        isHome = false
        url = target
        title = target.host(percentEncoded: false) ?? target.absoluteString
        webView.load(URLRequest(url: target))
    }

    func goHome() {
        webView.stopLoading()
        isHome = true
        isLoading = false
        estimatedProgress = 0
        title = "New Space"
        url = nil
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
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
    static func url(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        if looksLikeLocalAddress(trimmed), let url = URL(string: "http://\(trimmed)") {
            return url
        }

        if looksLikeDomain(trimmed), let url = URL(string: "https://\(trimmed)") {
            return url
        }

        return SearchEngine.selected.searchURL(for: trimmed)
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

struct BrowserPageContext: Sendable {
    var title: String
    var url: String
}
