import Foundation
@preconcurrency import WebKit

/// Per-tab orchestrator for inline completions. Owns the in-flight Task,
/// a small TTL+LRU response cache, and the path back into the page via
/// `evaluateJavaScript`. The bridge feeds it requests; coordinator hides
/// the model call and cancellation bookkeeping behind a single
/// `enqueue(payload:)` entry point.
@MainActor
final class InlineCompletionsCoordinator {
    weak var webView: WKWebView?

    private var activeSeq: Int = 0
    private var activeTask: Task<Void, Never>?
    private var cache: [String: CacheEntry] = [:]
    private let cacheLimit = 64
    private let cacheTTL: TimeInterval = 60

    private struct CacheEntry {
        var suggestion: String
        var insertedAt: Date
        var lastAccess: Date
    }

    init(webView: WKWebView?) {
        self.webView = webView
    }

    func enqueue(payload: InlineCompletionsBridge.RequestPayload) {
        activeSeq = payload.requestSeq
        let currentSeq = activeSeq

        if let cached = cachedSuggestion(for: payload.cacheKey) {
            deliver(suggestion: cached, seq: currentSeq, source: "cache")
            return
        }

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let suggestion = await Self.fetchSuggestion(for: payload)
            guard !Task.isCancelled, self.activeSeq == currentSeq else { return }
            if let suggestion {
                self.storeInCache(key: payload.cacheKey, suggestion: suggestion)
                self.deliver(suggestion: suggestion, seq: currentSeq, source: "model")
            } else {
                self.deliver(suggestion: "", seq: currentSeq, source: "empty")
            }
        }
    }

    func cancel(seq: Int) {
        if seq == activeSeq {
            activeTask?.cancel()
            activeTask = nil
        }
    }

    private func cachedSuggestion(for key: String) -> String? {
        guard let entry = cache[key] else { return nil }
        if Date().timeIntervalSince(entry.insertedAt) > cacheTTL {
            cache.removeValue(forKey: key)
            return nil
        }
        var refreshed = entry
        refreshed.lastAccess = Date()
        cache[key] = refreshed
        return entry.suggestion
    }

    private func storeInCache(key: String, suggestion: String) {
        let now = Date()
        cache[key] = CacheEntry(suggestion: suggestion, insertedAt: now, lastAccess: now)
        if cache.count > cacheLimit, let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func deliver(suggestion: String, seq: Int, source: String) {
        guard let webView else { return }
        let escapedSuggestion = Self.jsString(suggestion)
        let escapedSource = Self.jsString(source)
        let script = "window.__tbInline && window.__tbInline.deliver(\(seq), \(escapedSuggestion), \(escapedSource));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func fetchSuggestion(for payload: InlineCompletionsBridge.RequestPayload) async -> String? {
        let beforeRedaction = InlineCompletionsRedaction.redact(payload.textBefore)
        let afterRedaction = InlineCompletionsRedaction.redact(payload.textAfter)
        var redactedHints: [String: String] = [:]
        var hintsDidRedact = false
        for (key, value) in payload.siteHints {
            let r = InlineCompletionsRedaction.redact(value)
            redactedHints[key] = r.text
            hintsDidRedact = hintsDidRedact || r.didRedact
        }

        // If the user's text just before the cursor contains a secret, do
        // not autocomplete — the continuation could leak it further.
        if beforeRedaction.didRedact {
            return nil
        }

        let request = InlineCompletionsClient.Request(
            host: payload.host,
            pageTitle: payload.title,
            elementKind: payload.elementKind,
            elementLabel: payload.elementLabel,
            nearestHeading: payload.nearestHeading,
            siteHints: redactedHints,
            textBefore: beforeRedaction.text,
            textAfter: afterRedaction.text,
            redactionApplied: afterRedaction.didRedact || hintsDidRedact
        )

        do {
            return try await InlineCompletionsClient.complete(request)
        } catch {
            return nil
        }
    }

    /// Embed an arbitrary string as a JS string literal. JSONEncoder would
    /// also work but we'd then have to strip its surrounding object — this
    /// is cheaper and easier to audit.
    private static func jsString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
