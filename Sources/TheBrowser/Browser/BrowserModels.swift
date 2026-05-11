import AppKit
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
    @Published var selectionInfo: TextSelectionInfo?

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var searchBackStack: [BrowserSearchPage] = []
    private let selectionBridge: TextSelectionBridge
    private let citedClipboardBridge: CitedClipboardBridge

    /// Cited Clipboard capture gate. Returns false for tabs that should
    /// never feed the clipboard log — currently only the placeholder for
    /// future incognito mode, since ``BrowserTab`` doesn't yet have an
    /// incognito flag. When incognito ships, flip this off for those tabs.
    var allowsClipboardCapture: Bool { true }

    /// User agent used for both browsing tabs and the in-app Google sign-in
    /// sheet. WKWebView's default UA omits the `Version/X Safari/Y` suffix,
    /// which several Google properties (Accounts, YouTube, Gmail) treat as an
    /// "unsupported browser" and show a warning banner. We pin to Safari 18.5
    /// rather than the actual installed version because Google's UA support
    /// database lags newer Safari majors — using the previous major is the
    /// most reliable way to be recognized as a supported browser.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    override init() {
        let bridge = TextSelectionBridge()
        selectionBridge = bridge
        let citedBridge = CitedClipboardBridge()
        citedClipboardBridge = citedBridge

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(Self.darkModeUserScript)
        configuration.userContentController.addUserScript(Self.unsupportedBrowserBannerKillerScript)
        configuration.userContentController.addUserScript(Self.textSelectionUserScript)
        configuration.userContentController.addUserScript(CitedClipboardScript.userScript)
        configuration.userContentController.add(bridge, name: TextSelectionBridge.messageName)
        configuration.userContentController.add(citedBridge, name: CitedClipboardBridge.messageName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = .black

        super.init()

        bridge.tab = self
        citedBridge.tab = self
        webView.navigationDelegate = self
        observeWebView()
    }

    func applySelectionInfo(_ info: TextSelectionInfo?) {
        guard selectionInfo != info else { return }
        selectionInfo = info
    }

    func clearSelectionInfo() {
        selectionInfo = nil
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

        if isArtifact, let url {
            return BrowserTab.artifactAlias(for: url)
        }

        return url?.absoluteString ?? ""
    }

    /// Raw address shown when the URL bar is focused — exposes the actual
    /// URL the user can copy or edit. Differs from ``displayAddress`` only
    /// for artifacts, where ``displayAddress`` substitutes a friendly name.
    var editableAddress: String {
        if isHome {
            return ""
        }

        if let searchPage {
            return searchPage.query
        }

        return url?.absoluteString ?? ""
    }

    var isArtifact: Bool {
        guard let url, url.isFileURL else { return false }
        let artifactRoot = ArtifactStore.rootURL.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(artifactRoot)
    }

    var isSmartReadEligible: Bool {
        guard !isHome, searchPage == nil, let scheme = url?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// Turns an artifact file URL into a friendly label for the URL bar — e.g.
    /// `file:///…/2026-05-10_23-54-50_georgia-tech-school.html` becomes
    /// `Georgia Tech School`. Mirrors the `<stamp>_<slug>.html` format from
    /// ``ArtifactStore``; falls back to the bare filename stem if the
    /// timestamp prefix doesn't match.
    nonisolated static func artifactAlias(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let slug: String
        if let match = stem.firstMatch(of: #/^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_/#) {
            slug = String(stem[match.range.upperBound...])
        } else {
            slug = stem
        }
        let pretty = slug
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
        return pretty.isEmpty ? stem : pretty
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
            load(target)
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
        selectionInfo = nil
    }

    /// Loads a local file (typically a generated artifact) into this tab. Uses
    /// `loadFileURL(_:allowingReadAccessTo:)` so WKWebView grants the
    /// containing directory read access without complaining about the
    /// file:// scheme.
    func loadArtifact(at fileURL: URL) {
        webView.stopLoading()
        searchBackStack.removeAll()
        searchPage = nil
        isHome = false
        isLoading = true
        estimatedProgress = 0
        url = fileURL
        title = fileURL.deletingPathExtension().lastPathComponent
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    /// Extracts visible text content from the loaded page via JavaScript. Used
    /// by the AI chat's `read_tabs` tool to feed the model the user's open
    /// pages without a network round-trip. Returns nil for tabs without a
    /// loaded document (home tabs, search-result tabs).
    func extractVisibleText(maxBytes: Int = 6_000) async -> String? {
        guard !isHome, searchPage == nil else { return nil }
        let script = "document.body ? document.body.innerText : ''"
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script)
        } catch {
            return nil
        }
        guard let text = raw as? String else { return nil }
        let collapsed = text
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.utf8.count <= maxBytes {
            return collapsed
        }
        let prefix = String(collapsed.prefix(maxBytes))
        return prefix + "\n…[truncated]"
    }

    func extractReadableText(maxBytes: Int = 24_000) async -> String? {
        await extractReadablePage(maxBytes: maxBytes)?.text
    }

    func extractReadablePage(maxBytes: Int = 24_000) async -> ReadablePageExtraction? {
        guard isSmartReadEligible else { return nil }
        let script = """
        (() => {
            const selectors = [
                "article",
                "main",
                "[role='main']",
                ".post-content",
                ".entry-content",
                ".article-content",
                ".story-body"
            ];
            const score = (el) => {
                const text = (el.innerText || "").replace(/\\s+/g, " ").trim();
                if (!text) return { text, value: 0 };
                const paragraphs = el.querySelectorAll("p").length;
                return { text, value: text.length + paragraphs * 180 };
            };
            let best = score(document.body || document.documentElement);
            for (const selector of selectors) {
                for (const el of document.querySelectorAll(selector)) {
                    const candidate = score(el);
                    if (candidate.value > best.value) best = candidate;
                }
            }
            const text = best.text || "";
            const wordCount = (text.match(/\\S+/g) || []).length;
            return JSON.stringify({ text, wordCount });
        })();
        """
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script)
        } catch {
            guard let fallback = await extractVisibleText(maxBytes: maxBytes) else { return nil }
            return ReadablePageExtraction(
                text: fallback,
                wordCount: Self.wordCount(in: fallback)
            )
        }
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReadablePagePayload.self, from: data) else {
            return nil
        }
        let collapsed = Self.normalizeExtractedText(payload.text)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.utf8.count <= maxBytes {
            return ReadablePageExtraction(
                text: collapsed,
                wordCount: max(payload.wordCount, Self.wordCount(in: collapsed))
            )
        }
        let prefix = String(collapsed.prefix(maxBytes))
        return ReadablePageExtraction(
            text: prefix + "\n…[truncated]",
            wordCount: max(payload.wordCount, Self.wordCount(in: collapsed))
        )
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

    private func load(_ target: URL) {
        guard Self.isYouTubeURL(target),
              let cookie = Self.youtubeDarkModeCookie else {
            webView.load(URLRequest(url: target))
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak webView] in
            Task { @MainActor in
                webView?.load(URLRequest(url: target))
            }
        }
    }

    nonisolated private static func normalizeExtractedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func wordCount(in text: String) -> Int {
        text
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
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

    /// Forces dark presentation via CSS filter inversion, with a sample-and-strip
    /// fallback so sites that already paint dark aren't double-inverted.
    private static let darkModeUserScript = WKUserScript(
        source: """
        (() => {
            const FILTER_STYLE_ID = "thebrowser-force-dark-filter";
            const SCHEME_STYLE_ID = "thebrowser-dark-color-scheme";
            const BACKDROP_STYLE_ID = "thebrowser-dark-backdrop";

            const hostname = location.hostname || "";
            const isYouTube = hostname.endsWith("youtube.com");

            // Hosts where the filter approach causes more harm than good
            // (their own theming gets visibly destroyed, or they're styled
            // surfaces we already match). Skip the filter, keep color-scheme.
            const FILTER_SKIP_HOSTS = [
                "youtube.com",
                "accounts.google.com",
                "accounts.youtube.com"
            ];
            const shouldSkipFilter = FILTER_SKIP_HOSTS.some((host) =>
                hostname === host || hostname.endsWith("." + host)
            );

            const forceYouTubeDarkMode = () => {
                if (!isYouTube) {
                    return;
                }

                const cookieParts = document.cookie.split(";").map((part) => part.trim());
                const prefCookie = cookieParts.find((part) => part.startsWith("PREF="));
                const prefValue = prefCookie ? decodeURIComponent(prefCookie.substring(5)) : "";
                const hadDarkPreference = /(?:^|&)f6=400(?:&|$)/.test(prefValue);
                const prefSettings = new URLSearchParams(prefValue);
                prefSettings.set("f6", "400");

                document.cookie = `PREF=${prefSettings.toString()}; path=/; domain=.youtube.com; max-age=31536000; SameSite=Lax`;
                document.documentElement?.setAttribute("dark", "");

                if (!hadDarkPreference && !sessionStorage.getItem("thebrowser-youtube-dark-reload")) {
                    sessionStorage.setItem("thebrowser-youtube-dark-reload", "1");
                    location.reload();
                }
            };

            const applyDarkColorScheme = () => {
                if (!document.documentElement || document.getElementById(SCHEME_STYLE_ID)) {
                    return;
                }

                const style = document.createElement("style");
                style.id = SCHEME_STYLE_ID;
                style.textContent = ":root { color-scheme: dark !important; }";
                document.documentElement.appendChild(style);
            };

            // Painted even on skipped hosts so the first frame isn't white
            // before the site's own styles arrive.
            const applyDarkBackdrop = () => {
                if (!document.documentElement || document.getElementById(BACKDROP_STYLE_ID)) {
                    return;
                }
                const style = document.createElement("style");
                style.id = BACKDROP_STYLE_ID;
                style.textContent = "html { background-color: #1a1a1a; }";
                document.documentElement.appendChild(style);
            };

            const installFilter = () => {
                if (!document.documentElement || document.getElementById(FILTER_STYLE_ID)) {
                    return;
                }
                const style = document.createElement("style");
                style.id = FILTER_STYLE_ID;
                // The ::selection rule is co-located with the filter on
                // purpose. The default browser selection color gets badly
                // mangled by invert + hue-rotate — most light themes
                // collapse the highlight to a near-opaque dark rectangle
                // that hides the selected text. A translucent black overlay
                // before inversion ends up as a translucent white overlay
                // afterwards (the conventional dark-mode selection look),
                // and `color: inherit` keeps the text readable inside it.
                // Sites where the filter is skipped or later removed get
                // their native selection because the rule is dropped with
                // the rest of this style element.
                style.textContent = `
                    html {
                        filter: invert(1) hue-rotate(180deg) !important;
                        background-color: #ffffff !important;
                    }
                    img, picture, video, iframe, embed, object, canvas,
                    svg image,
                    [style*="background-image"],
                    [style*="background:url"],
                    [style*="background: url"] {
                        filter: invert(1) hue-rotate(180deg) !important;
                    }
                    ::selection {
                        background-color: rgba(0, 0, 0, 0.42) !important;
                        color: inherit !important;
                    }
                    ::-moz-selection {
                        background-color: rgba(0, 0, 0, 0.42) !important;
                        color: inherit !important;
                    }
                `;
                document.documentElement.appendChild(style);
            };

            const removeFilter = () => {
                document.getElementById(FILTER_STYLE_ID)?.remove();
            };

            const parseColor = (value) => {
                if (!value) return null;
                const match = value.match(/rgba?\\((\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\)/);
                if (!match) return null;
                const r = parseInt(match[1], 10);
                const g = parseInt(match[2], 10);
                const b = parseInt(match[3], 10);
                const a = match[4] !== undefined ? parseFloat(match[4]) : 1;
                return { r, g, b, a };
            };

            const luminance = (rgb) => 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;

            const reconcileWithSiteTheme = () => {
                if (shouldSkipFilter) {
                    return;
                }
                const body = document.body;
                if (!body) {
                    return;
                }

                // Disable our filter while sampling so we read the site's
                // own painted colors, not the inverted-by-us ones.
                const filterStyle = document.getElementById(FILTER_STYLE_ID);
                if (filterStyle) filterStyle.disabled = true;

                let bg = parseColor(getComputedStyle(body).backgroundColor);
                if (!bg || bg.a === 0) {
                    bg = parseColor(getComputedStyle(document.documentElement).backgroundColor);
                }

                if (filterStyle) filterStyle.disabled = false;

                if (!bg || bg.a === 0) {
                    return;
                }

                if (luminance(bg) < 128) {
                    removeFilter();
                }
            };

            applyDarkBackdrop();
            applyDarkColorScheme();
            forceYouTubeDarkMode();
            if (!shouldSkipFilter) {
                installFilter();
            }

            const onReady = () => {
                applyDarkBackdrop();
                applyDarkColorScheme();
                forceYouTubeDarkMode();
                reconcileWithSiteTheme();
            };

            if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", onReady, { once: true });
            } else {
                onReady();
            }
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Removes Google's "this browser is no longer supported" banner across
    /// products. Several Google web apps render this banner client-side based
    /// on a User-Agent allowlist that lags real Safari versions; rather than
    /// chase the UA, we strip the banner from the DOM after it appears.
    static let unsupportedBrowserBannerKillerScript = WKUserScript(
        source: """
        (() => {
            const PHRASES = [
                'browser version is no longer supported',
                'no longer supported. please upgrade',
                'upgrade to a supported browser',
                'this browser is no longer supported',
                'browser is not supported',
                'use a supported browser'
            ];

            const matchesBannerText = (text) => {
                if (!text) return false;
                const trimmed = text.trim();
                if (trimmed.length === 0 || trimmed.length > 600) return false;
                const lower = trimmed.toLowerCase();
                return PHRASES.some((phrase) => lower.includes(phrase));
            };

            const removeBanners = () => {
                const candidates = document.querySelectorAll(
                    'div, section, aside, header, footer, span, p, tp-yt-paper-toast, ytd-popup-container'
                );
                for (const el of candidates) {
                    if (!matchesBannerText(el.textContent || '')) continue;
                    let target = el;
                    while (
                        target.parentElement &&
                        target.parentElement.tagName !== 'BODY' &&
                        target.parentElement.tagName !== 'HTML' &&
                        matchesBannerText(target.parentElement.textContent || '')
                    ) {
                        target = target.parentElement;
                    }
                    try { target.remove(); } catch (_) {}
                }
            };

            const start = () => {
                removeBanners();
                const observer = new MutationObserver((mutations) => {
                    for (const mutation of mutations) {
                        for (const node of mutation.addedNodes) {
                            if (node.nodeType !== 1) continue;
                            if (matchesBannerText(node.textContent || '')) {
                                removeBanners();
                                return;
                            }
                        }
                    }
                });
                observer.observe(document.documentElement, { childList: true, subtree: true });
            };

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', start, { once: true });
            } else {
                start();
            }
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static var youtubeDarkModeCookie: HTTPCookie? {
        HTTPCookie(properties: [
            .domain: ".youtube.com",
            .path: "/",
            .name: "PREF",
            .value: "f6=400",
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
        ])
    }

    private static func isYouTubeURL(_ url: URL) -> Bool {
        url.host(percentEncoded: false)?.hasSuffix("youtube.com") == true
    }
}

extension BrowserTab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.isHome = false
            self.isLoading = true
            self.selectionInfo = nil
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

struct ReadablePageExtraction: Equatable {
    var text: String
    var wordCount: Int
}

private struct ReadablePagePayload: Decodable {
    var text: String
    var wordCount: Int
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

/// One row in the open-tabs manifest passed to the AI prompt. `index` is
/// 1-based so it lines up with how the manifest is rendered to the model.
/// `isContent` is false for home and search tabs, which have no real page
/// content to extract.
struct TabManifestEntry: Sendable, Equatable {
    var index: Int
    var title: String
    var url: String
    var isSelected: Bool
    var isContent: Bool
}
