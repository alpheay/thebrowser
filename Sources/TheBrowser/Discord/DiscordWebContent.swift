import AppKit
import SwiftUI
@preconcurrency import WebKit

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        context.coordinator.lastRequestedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Diff against the LAST URL WE REQUESTED rather than `nsView.url`,
        // because Discord's SPA frequently rewrites the displayed URL to a
        // resolved channel id (e.g. `/channels/123/789`) — comparing against
        // the live URL would cause us to re-issue `load(...)` on every parent
        // re-render and trash Discord's router state.
        if context.coordinator.lastRequestedURL != url {
            context.coordinator.lastRequestedURL = url
            nsView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator {
        var lastRequestedURL: URL?
    }
}
