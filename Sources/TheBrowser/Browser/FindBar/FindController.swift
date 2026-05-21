import Foundation
@preconcurrency import WebKit

/// Per-tab Find in Page state and WebKit wrapper. WebKit's native find
/// (``WKWebView/find(_:configuration:completionHandler:)``) handles
/// highlighting and selection-cycling but reports only `matchFound`, so
/// the "3 of 12" counter is sourced from a small JS pass over
/// `document.body.innerText`. The two can drift on pages that hide text
/// behind `display: none` or move it into shadow DOM, but for normal
/// articles they line up.
///
/// In conversational mode (``isAIMode``), the user types a natural-language
/// question instead of a literal needle. On submit we send the question plus
/// the page's visible text to ``ConversationalFindClient``, which returns a
/// verbatim substring that we then feed through the same WebKit find
/// pipeline — so highlighting, prev/next, and the "X of Y" counter all keep
/// working without forking the search code path.
@MainActor
final class FindController: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var isVisible: Bool = false
    @Published private(set) var totalMatches: Int = 0
    @Published private(set) var currentMatch: Int = 0
    /// Bumped by ``show()`` so the bar's text field can re-focus even when
    /// it's already on screen (matches every other browser's ⌘F behavior).
    @Published private(set) var focusRequestToken: Int = 0

    /// Whether the bar is currently interpreting the input as a conversational
    /// query rather than a literal substring.
    @Published var isAIMode: Bool = false
    /// True while an LLM round-trip for the current query is in flight.
    @Published private(set) var aiSearching: Bool = false
    /// The verbatim substring the LLM picked for the most recent AI query.
    /// Drives ``effectiveNeedle`` (and therefore highlighting and counting).
    @Published private(set) var aiResolvedPhrase: String?
    /// User-visible error from the most recent AI query (e.g. "no match",
    /// missing CLI, empty response). Cleared as soon as the user edits the
    /// query or resubmits.
    @Published private(set) var aiError: String?

    /// Closure that returns the live `WKWebView` for the owning tab — `nil`
    /// when the tab is hibernated or hasn't mounted yet. Lives as a closure
    /// rather than a stored reference so hibernation/resurrect cycles don't
    /// strand a stale pointer here.
    var webViewProvider: (() -> WKWebView?)?

    private var countTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?

    /// The actual needle passed to WebKit. In literal mode it's the user's
    /// typed query; in AI mode it's whatever phrase the LLM resolved (or nil
    /// before the first successful resolution).
    private var effectiveNeedle: String {
        if isAIMode {
            return aiResolvedPhrase ?? ""
        }
        return query
    }

    func show() {
        isVisible = true
        focusRequestToken &+= 1
        let needle = effectiveNeedle
        if !needle.isEmpty {
            scheduleCountMatches()
            runFind(forward: true, reset: true)
        }
    }

    /// Re-runs the current query without re-focusing the text field. Called
    /// after page navigation so the counter and highlight reflect fresh
    /// content even while the user's focus is somewhere else (e.g. the
    /// page they just opened).
    ///
    /// In AI mode we deliberately drop the resolved phrase on navigation
    /// rather than re-firing the LLM — the previous answer almost certainly
    /// doesn't apply to the new page, and silently re-billing would be
    /// surprising.
    func rerunForNavigation() {
        guard isVisible else { return }
        if isAIMode {
            aiTask?.cancel()
            aiSearching = false
            aiResolvedPhrase = nil
            aiError = nil
            totalMatches = 0
            currentMatch = 0
            clearWebKitHighlight()
            return
        }
        guard !query.isEmpty else { return }
        totalMatches = 0
        currentMatch = 0
        scheduleCountMatches()
        runFind(forward: true, reset: true)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        countTask?.cancel()
        aiTask?.cancel()
        aiSearching = false
        clearWebKitHighlight()
    }

    func updateQuery(_ text: String) {
        guard query != text else { return }
        query = text
        if isAIMode {
            // Typing a new question invalidates the previous AI result; we
            // wait for an explicit submit (Enter) before paying for another
            // LLM round trip.
            aiResolvedPhrase = nil
            aiError = nil
            totalMatches = 0
            currentMatch = 0
            countTask?.cancel()
            clearWebKitHighlight()
            return
        }
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

    /// Toggles between literal and conversational interpretation of the
    /// input. Either direction clears the find state so the new mode starts
    /// fresh — keeping a stale highlight from the previous mode would be
    /// more confusing than starting clean.
    func toggleAIMode() {
        setAIMode(!isAIMode)
    }

    func setAIMode(_ enabled: Bool) {
        guard isAIMode != enabled else { return }
        isAIMode = enabled
        aiTask?.cancel()
        aiSearching = false
        aiResolvedPhrase = nil
        aiError = nil
        totalMatches = 0
        currentMatch = 0
        countTask?.cancel()
        clearWebKitHighlight()
    }

    /// Called on Enter. In literal mode this just moves to the next match
    /// (matching the previous behavior). In AI mode it fires off (or, if a
    /// resolved phrase already exists for the unchanged query, just advances).
    func submit() {
        if isAIMode {
            if aiResolvedPhrase != nil {
                next()
            } else {
                runAIQuery()
            }
        } else {
            next()
        }
    }

    func next() {
        guard !effectiveNeedle.isEmpty else { return }
        runFind(forward: true, reset: false)
    }

    func previous() {
        guard !effectiveNeedle.isEmpty else { return }
        runFind(forward: false, reset: false)
    }

    /// Sends the user's natural-language query plus the page's visible text
    /// to the configured fast model, then routes the resolved verbatim phrase
    /// through the normal WebKit find pipeline.
    func runAIQuery() {
        guard isAIMode else { return }
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        aiTask?.cancel()
        aiResolvedPhrase = nil
        aiError = nil
        totalMatches = 0
        currentMatch = 0
        clearWebKitHighlight()
        aiSearching = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.aiSearching = false }
            let pageText: String
            do {
                pageText = try await self.fetchPageText()
            } catch {
                if !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == question {
                    self.aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                return
            }
            if Task.isCancelled { return }
            let result: ConversationalFindClient.Result
            do {
                result = try await ConversationalFindClient.resolve(question: question, pageText: pageText)
            } catch {
                if !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == question {
                    self.aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                return
            }
            if Task.isCancelled { return }
            guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == question else { return }
            switch result {
            case .noMatch:
                self.aiError = "No match for that on this page."
            case .phrase(let phrase):
                self.aiResolvedPhrase = phrase
                self.scheduleCountMatches()
                self.runFind(forward: true, reset: true)
            }
        }
    }

    private func runFind(forward: Bool, reset: Bool) {
        let needle = effectiveNeedle
        guard let webView = webViewProvider?(), !needle.isEmpty else {
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true

        let issuedNeedle = needle
        webView.find(issuedNeedle, configuration: configuration) { [weak self] result in
            Task { @MainActor in
                guard let self, self.effectiveNeedle == issuedNeedle else { return }
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
                    // In AI mode this means the model returned a phrase that
                    // isn't actually on the page (it hallucinated or
                    // paraphrased despite instructions). Surface that as a
                    // miss rather than silently leaving the bar empty.
                    if self.isAIMode, self.aiError == nil {
                        self.aiError = "AI suggested a phrase that isn't on this page."
                        self.aiResolvedPhrase = nil
                    }
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

    /// Counts occurrences of the current effective needle in the page text
    /// via a short JS pass. Debounced so rapid typing doesn't spawn many
    /// in-flight evaluations; the latest task wins.
    private func scheduleCountMatches() {
        countTask?.cancel()
        let issuedNeedle = effectiveNeedle
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self, self.effectiveNeedle == issuedNeedle else {
                return
            }
            await self.countMatches(for: issuedNeedle)
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
        guard self.effectiveNeedle == needle else { return }
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

    /// Pulls the page's visible text for the AI prompt. Mirrors the strategy
    /// already used by ``countMatches(for:)`` (read `document.body.innerText`)
    /// so we share whatever fidelity / edge cases the rest of the find code
    /// has — keeping the literal counter and the AI input grounded in the
    /// same view of the page.
    private func fetchPageText() async throws -> String {
        guard let webView = webViewProvider?() else {
            throw ConversationalFindError.emptyPage
        }
        let script = "(document.body && document.body.innerText) || \"\""
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script)
        } catch {
            throw ConversationalFindError.emptyPage
        }
        let text = (raw as? String) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConversationalFindError.emptyPage
        }
        return text
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
