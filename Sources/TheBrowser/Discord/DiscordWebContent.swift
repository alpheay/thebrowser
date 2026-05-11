import AppKit
import SwiftUI
@preconcurrency import WebKit

enum DiscordWebLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Imperative handle the SwiftUI side uses to drive an embedded
/// `WKWebView`. Holds a weak reference to the live web view and re-publishes
/// navigation state so the header strip can render a spinner / error chip /
/// "Reload" button without owning the WebKit object directly.
@MainActor
final class DiscordWebController: ObservableObject {
    @Published var loadingState: DiscordWebLoadingState = .idle
    @Published var currentURL: URL?

    weak var webView: WKWebView?

    func reload() {
        webView?.reload()
    }

    func loadFresh() {
        // Bypasses the WKWebView page cache. Used when the user hits Reload
        // because the page is in a broken state — a normal `reload()` would
        // re-serve whatever broken response WebKit cached.
        guard let webView, let url = currentURL else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }
}

/// Embedded `discord.com` view themed to match The Browser.
///
/// We share the default `WKWebsiteDataStore` with the OAuth sheet so the
/// session cookies set during sign-in carry over — the user is already
/// authenticated when this loads.
///
/// `DiscordTheme.injectionScript` runs at `atDocumentStart`, before Discord's
/// first paint, so the user never sees a flash of un-themed (blurple) UI.
struct DiscordWebContent: NSViewRepresentable {
    let url: URL
    @ObservedObject var controller: DiscordWebController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: DiscordTheme.injectionScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = NSColor.black
        webView.customUserAgent = BrowserTab.userAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.lastRequestedURL = url
        controller.webView = webView
        controller.currentURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        controller.webView = nsView
        if context.coordinator.lastRequestedURL != url {
            context.coordinator.lastRequestedURL = url
            controller.currentURL = url
            nsView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRequestedURL: URL?
        let controller: DiscordWebController

        init(controller: DiscordWebController) {
            self.controller = controller
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            Task { @MainActor in
                self.controller.loadingState = .loading
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            Task { @MainActor in
                self.controller.loadingState = .loaded
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let message = error.localizedDescription
            Task { @MainActor in
                self.controller.loadingState = .failed(message)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let message = error.localizedDescription
            Task { @MainActor in
                self.controller.loadingState = .failed(message)
            }
        }
    }
}
