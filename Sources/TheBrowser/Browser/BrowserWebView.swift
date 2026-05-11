import SwiftUI
@preconcurrency import WebKit

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab

    func makeNSView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
