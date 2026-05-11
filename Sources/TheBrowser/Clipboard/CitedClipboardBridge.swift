import AppKit
import Foundation
@preconcurrency import WebKit

/// JS → Swift channel for the cited clipboard. Held weakly by its owning
/// ``BrowserTab`` to avoid the standard
/// `WKUserContentController → handler → tab → webView → handler` retain cycle.
final class CitedClipboardBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    static let messageName = "thebrowserCitedClipboard"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any] else {
            return
        }

        let text = (body["text"] as? String) ?? ""
        let html = (body["html"] as? String) ?? ""
        let sentenceBefore = (body["sentenceBefore"] as? String) ?? ""
        let sentenceAfter = (body["sentenceAfter"] as? String) ?? ""

        // WKScriptMessageHandler is invoked on the main thread per the WebKit
        // contract — hop through `Task @MainActor` to satisfy strict
        // concurrency, and read source URL/title off the owning tab rather
        // than trusting any fields the JS side put on the payload.
        Task { @MainActor [weak tab] in
            guard let tab else { return }
            CitedClipboardController.shared.recordCopy(
                text: text,
                html: html,
                sentenceBefore: sentenceBefore,
                sentenceAfter: sentenceAfter,
                tab: tab
            )
        }
    }
}
