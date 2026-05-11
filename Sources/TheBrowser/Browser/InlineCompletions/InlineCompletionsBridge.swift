import Foundation
@preconcurrency import WebKit

extension Notification.Name {
    static let inlineCompletionsSettingsChanged = Notification.Name("thebrowser.inlineCompletions.settingsChanged")
}

/// JS → Swift handler for inline completion requests. Held by the user
/// content controller; the page calls in via `request` / `cancel` /
/// `ready`, and the bridge replies through `evaluateJavaScript` calls on
/// the coordinator.
final class InlineCompletionsBridge: NSObject, WKScriptMessageHandler {
    /// `nonisolated` so it can be referenced from the user-script's source
    /// literal (a non-isolated static) without dragging MainActor isolation
    /// through the interpolation site.
    nonisolated static let messageName = "thebrowserInlineCompletion"

    private var coordinator: InlineCompletionsCoordinator?
    private weak var attachedWebView: WKWebView?
    /// `nonisolated(unsafe)`: only assigned during `init` (before the
    /// instance escapes) and only read during `deinit` (after the last
    /// reference goes away), so the lack of explicit isolation is safe.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    struct RequestPayload {
        var requestSeq: Int
        var cacheKey: String
        var host: String
        var title: String
        var elementKind: String
        var elementLabel: String
        var nearestHeading: String
        var siteHints: [String: String]
        var textBefore: String
        var textAfter: String
    }

    override init() {
        super.init()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .inlineCompletionsSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sendSettings()
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @MainActor
    func attach(to webView: WKWebView) {
        attachedWebView = webView
        if coordinator == nil {
            coordinator = InlineCompletionsCoordinator(webView: webView)
        } else {
            coordinator?.webView = webView
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else {
            return
        }
        Task { @MainActor [weak self] in
            self?.handle(kind: kind, body: body)
        }
    }

    @MainActor
    private func handle(kind: String, body: [String: Any]) {
        switch kind {
        case "request":
            guard let payload = Self.parseRequest(body) else { return }
            let settings = InlineCompletionsSettings.current()
            guard settings.allows(host: payload.host) else {
                replyDisabled(seq: payload.requestSeq)
                return
            }
            coordinator?.enqueue(payload: payload)
        case "cancel":
            let seq = (body["requestSeq"] as? NSNumber)?.intValue ?? 0
            coordinator?.cancel(seq: seq)
        case "ready":
            sendSettings()
        default:
            break
        }
    }

    @MainActor
    func sendSettings() {
        guard let webView = attachedWebView else { return }
        let settings = InlineCompletionsSettings.current()
        let payload: [String: Any] = [
            "isEnabled": settings.isEnabled,
            "triggerDelayMs": settings.triggerDelayMs,
            "renderMode": settings.renderMode,
            "allowList": settings.allowList,
            "blockList": settings.blockList,
            "isIncognito": false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__tbInline && window.__tbInline.applySettings(\(json));", completionHandler: nil)
    }

    @MainActor
    private func replyDisabled(seq: Int) {
        guard let webView = attachedWebView else { return }
        webView.evaluateJavaScript(
            "window.__tbInline && window.__tbInline.deliver(\(seq), \"\", \"disabled\");",
            completionHandler: nil
        )
    }

    private static func parseRequest(_ body: [String: Any]) -> RequestPayload? {
        guard let seq = (body["requestSeq"] as? NSNumber)?.intValue,
              let cacheKey = body["cacheKey"] as? String,
              let host = body["host"] as? String,
              let elementKind = body["elementKind"] as? String,
              let textBefore = body["textBefore"] as? String,
              let textAfter = body["textAfter"] as? String else {
            return nil
        }
        let title = body["title"] as? String ?? ""
        let label = body["elementLabel"] as? String ?? ""
        let heading = body["nearestHeading"] as? String ?? ""
        let rawHints = body["siteHints"] as? [String: Any] ?? [:]
        var hints: [String: String] = [:]
        for (key, value) in rawHints {
            if let stringValue = value as? String, !stringValue.isEmpty {
                hints[key] = stringValue
            }
        }
        return RequestPayload(
            requestSeq: seq,
            cacheKey: cacheKey,
            host: host,
            title: title,
            elementKind: elementKind,
            elementLabel: label,
            nearestHeading: heading,
            siteHints: hints,
            textBefore: textBefore,
            textAfter: textAfter
        )
    }
}
