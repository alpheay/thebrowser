import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// A live OAuth web sign-in request the view layer is asked to present.
///
/// The store creates one of these and exposes it via `@Published`. The view
/// binds a `.sheet(item:)` to it. When the embedded webview catches the
/// redirect URI (or the user cancels), the request resumes the underlying
/// continuation in the auth service.
@MainActor
final class WebAuthRequest: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let callbackScheme: String

    private let onResult: (Result<URL, Error>) -> Void
    private var settled = false

    init(url: URL, callbackScheme: String, onResult: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.callbackScheme = callbackScheme
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
        onResult(.failure(GoogleAuthError.authorizationCanceled))
    }

    func fail(_ error: Error) {
        guard !settled else { return }
        settled = true
        onResult(.failure(error))
    }
}

struct GoogleAuthWebSheet: View {
    @ObservedObject var request: WebAuthRequest

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            AuthWebView(request: request)
                .frame(minWidth: 520, minHeight: 640)
        }
        .background(Color.black)
        .frame(minWidth: 520, minHeight: 700)
        .onDisappear {
            // If the user dismisses the sheet by other means (Esc, system close)
            // before the webview catches the redirect, treat it as cancellation.
            request.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
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
    let request: WebAuthRequest

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Share the persistent cookie jar with the main browsing webviews so
        // session cookies set during sign-in (SID, __Secure-1PSID, …) make
        // YouTube/Gmail/Drive immediately appear logged in afterwards.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(BrowserTab.unsupportedBrowserBannerKillerScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = .black
        // Match the main browsing tabs so cookies set during sign-in are
        // recognized as belonging to the same "browser" by Google's UA sniffer.
        webView.customUserAgent = BrowserTab.userAgent
        webView.load(URLRequest(url: request.url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let request: WebAuthRequest

        init(request: WebAuthRequest) {
            self.request = request
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            let target = request.callbackScheme.lowercased()
            if let url, scheme == target {
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
            // Custom-scheme cancellations land here too; ignore those — they're
            // expected and handled in decidePolicyFor.
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorUnsupportedURL || nsError.code == NSURLErrorCancelled {
                return
            }
            request.fail(GoogleAuthError.authorizationFailed(error.localizedDescription))
        }
    }
}
