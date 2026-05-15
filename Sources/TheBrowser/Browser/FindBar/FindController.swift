import Foundation
@preconcurrency import WebKit

/// Per-tab Find in Page state and WebKit wrapper. WebKit's native find
/// (``WKWebView/find(_:configuration:completionHandler:)``) handles
/// highlighting and selection-cycling but reports only `matchFound`, so
/// the "3 of 12" counter is sourced from a small JS pass over
/// `document.body.innerText`. The two can drift on pages that hide text
/// behind `display: none` or move it into shadow DOM, but for normal
/// articles they line up.
@MainActor
final class FindController: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var isVisible: Bool = false
    @Published private(set) var totalMatches: Int = 0
    @Published private(set) var currentMatch: Int = 0
    /// Bumped by ``show()`` so the bar's text field can re-focus even when
    /// it's already on screen (matches every other browser's ⌘F behavior).
    @Published private(set) var focusRequestToken: Int = 0

    /// Closure that returns the live `WKWebView` for the owning tab — `nil`
    /// when the tab is hibernated or hasn't mounted yet. Lives as a closure
    /// rather than a stored reference so hibernation/resurrect cycles don't
    /// strand a stale pointer here.
    var webViewProvider: (() -> WKWebView?)?

    private var countTask: Task<Void, Never>?

    func show() {
        isVisible = true
        focusRequestToken &+= 1
        if !query.isEmpty {
            scheduleCountMatches()
            runFind(forward: true, reset: true)
        }
    }

    /// Re-runs the current query without re-focusing the text field. Called
    /// after page navigation so the counter and highlight reflect fresh
    /// content even while the user's focus is somewhere else (e.g. the
    /// page they just opened).
    func rerunForNavigation() {
        guard isVisible, !query.isEmpty else { return }
        totalMatches = 0
        currentMatch = 0
        scheduleCountMatches()
        runFind(forward: true, reset: true)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        countTask?.cancel()
        clearWebKitHighlight()
    }

    func updateQuery(_ text: String) {
        guard query != text else { return }
        query = text
        if text.isEmpty {
            totalMatches = 0
            currentMatch = 0
            countTask?.cancel()
            clearWebKitHighlight()
            return
        }
        scheduleCountMatches()
        runFind(forward: true, reset: true)
    }

    func next() {
        guard !query.isEmpty else { return }
        runFind(forward: true, reset: false)
    }

    func previous() {
        guard !query.isEmpty else { return }
        runFind(forward: false, reset: false)
    }

    private func runFind(forward: Bool, reset: Bool) {
        guard let webView = webViewProvider?(), !query.isEmpty else {
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true

        let issuedQuery = query
        webView.find(issuedQuery, configuration: configuration) { [weak self] result in
            Task { @MainActor in
                guard let self, self.query == issuedQuery else { return }
                if result.matchFound {
                    if reset {
                        self.currentMatch = 1
                    } else {
                        self.advanceCurrentMatch(forward: forward)
                    }
                    // If the JS count is still pending, make sure the
                    // displayed "X/Y" never shows X > Y. The pending count
                    // will replace this with the real total shortly.
                    if self.totalMatches < self.currentMatch {
                        self.totalMatches = self.currentMatch
                    }
                } else {
                    self.totalMatches = 0
                    self.currentMatch = 0
                }
            }
        }
    }

    private func advanceCurrentMatch(forward: Bool) {
        guard totalMatches > 0 else {
            currentMatch = max(1, currentMatch)
            return
        }
        if forward {
            currentMatch = currentMatch >= totalMatches ? 1 : currentMatch + 1
        } else {
            currentMatch = currentMatch <= 1 ? totalMatches : currentMatch - 1
        }
    }

    /// Counts occurrences of the current query in the page text via a
    /// short JS pass. Debounced so rapid typing doesn't spawn many in-flight
    /// evaluations; the latest task wins.
    private func scheduleCountMatches() {
        countTask?.cancel()
        let issuedQuery = query
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, self.query == issuedQuery else {
                return
            }
            await self.countMatches(for: issuedQuery)
        }
    }

    private func countMatches(for needle: String) async {
        guard let webView = webViewProvider?(), !needle.isEmpty else {
            return
        }
        let encodedNeedle = Self.encodeForJavaScript(needle)
        let script = """
        (function() {
            const needle = \(encodedNeedle);
            if (!needle) return 0;
            const body = document.body;
            if (!body) return 0;
            const haystack = (body.innerText || "").toLowerCase();
            const lowerNeedle = needle.toLowerCase();
            if (!lowerNeedle) return 0;
            let count = 0;
            let pos = 0;
            while ((pos = haystack.indexOf(lowerNeedle, pos)) !== -1) {
                count++;
                pos += lowerNeedle.length;
            }
            return count;
        })();
        """
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script)
        } catch {
            return
        }
        guard self.query == needle else { return }
        let count = (raw as? Int) ?? ((raw as? NSNumber)?.intValue ?? 0)
        self.totalMatches = count
        if count == 0 {
            self.currentMatch = 0
        } else if self.currentMatch == 0 {
            self.currentMatch = 1
        } else if self.currentMatch > count {
            self.currentMatch = count
        }
    }

    /// Drops the highlight WKWebView leaves behind after a find. Calling
    /// `find` with an empty string is a no-op, so we collapse the page
    /// selection instead.
    private func clearWebKitHighlight() {
        guard let webView = webViewProvider?() else { return }
        webView.evaluateJavaScript(
            "window.getSelection && window.getSelection().removeAllRanges();",
            completionHandler: nil
        )
    }

    /// JSON-encodes `value` so it can be safely embedded as a JS string
    /// literal — covers backslashes, quotes, newlines, and the U+2028 /
    /// U+2029 line terminators that JSON allows raw but JS doesn't.
    private static func encodeForJavaScript(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        return "\"\""
    }
}
