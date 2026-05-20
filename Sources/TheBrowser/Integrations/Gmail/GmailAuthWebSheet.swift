import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// Live OAuth web sign-in request the Gmail integration asks the view layer
/// to present. Mirrors ``WebAuthRequest`` (Google sign-in) but the callback
/// is matched on host (`localhost`) instead of a reverse-DNS scheme, since
/// the Gmail OAuth client is a Desktop type with `http://localhost` as its
/// redirect URI.
@MainActor
final class GmailWebAuthRequest: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let callbackHost: String

    private let onResult: (Result<URL, Error>) -> Void
    private var settled = false

    init(url: URL, callbackHost: String, onResult: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.callbackHost = callbackHost
        self.onResult = onResult
    }

    func complete(callbackURL: URL) {
        guard !settled else { return }
        settled = true
        onResult(.success(callbackURL))
    }

    func cancel() {
        guard !settled else { return }
        settled = true
        onResult(.failure(GmailAuthError.authorizationCanceled))
    }

    func fail(_ error: Error) {
        guard !settled else { return }
        settled = true
        onResult(.failure(error))
    }
}

struct GmailAuthWebSheet: View {
    @ObservedObject var request: GmailWebAuthRequest

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            AuthWebView(request: request)
                .frame(minWidth: 520, minHeight: 640)
        }
        .background(Color.black)
        .frame(minWidth: 520, minHeight: 700)
        .onDisappear { request.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("accounts.google.com")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button {
                request.cancel()
            } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

private struct AuthWebView: NSViewRepresentable {
    let request: GmailWebAuthRequest

    func makeCoordinator() -> Coordinator { Coordinator(request: request) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(BrowserTab.unsupportedBrowserBannerKillerScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = .black
        webView.customUserAgent = BrowserTab.userAgent
        webView.load(URLRequest(url: request.url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let request: GmailWebAuthRequest

        init(request: GmailWebAuthRequest) {
            self.request = request
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // Desktop OAuth redirects come back as `http://localhost/?code=...`.
            // Cancel the navigation before WebKit actually tries to hit
            // 127.0.0.1 (which isn't listening — nothing good would happen).
            if let url = navigationAction.request.url,
               url.scheme?.lowercased() == "http",
               url.host?.lowercased() == request.callbackHost.lowercased() {
                decisionHandler(.cancel)
                request.complete(callbackURL: url)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            // Custom-host cancellations land here too; ignore the expected ones.
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorUnsupportedURL || nsError.code == NSURLErrorCancelled {
                return
            }
            request.fail(GmailAuthError.authorizationFailed(error.localizedDescription))
        }
    }
}
