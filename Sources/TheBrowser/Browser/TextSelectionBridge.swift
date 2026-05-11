import AppKit
import Foundation
@preconcurrency import WebKit

/// One observed text selection inside a tab's web content. Coordinates are in
/// the WKWebView's viewport space (CSS pixels relative to the visible
/// viewport, which line up 1:1 with SwiftUI overlay points on retina and
/// non-retina alike).
struct TextSelectionInfo: Equatable {
    var text: String
    var rect: CGRect
}

/// JS → Swift message handler that watches the page for text selections and
/// forwards them to the owning ``BrowserTab``. Held weakly to avoid the
/// retain cycle WKUserContentController → handler → tab → webView → handler.
final class TextSelectionBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    static let messageName = "thebrowserSelectionChange"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any] else {
            return
        }

        let visible = body["visible"] as? Bool ?? false
        let text = body["text"] as? String ?? ""
        let x = (body["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (body["y"] as? NSNumber)?.doubleValue ?? 0
        let width = (body["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (body["height"] as? NSNumber)?.doubleValue ?? 0
        let rect = CGRect(x: x, y: y, width: width, height: height)

        let payload: TextSelectionInfo? = (visible && !text.isEmpty)
            ? TextSelectionInfo(text: text, rect: rect)
            : nil

        // WKScriptMessageHandler is invoked on the main thread per the WebKit
        // contract; jump through Task @MainActor to satisfy strict concurrency.
        Task { @MainActor [weak tab] in
            tab?.applySelectionInfo(payload)
        }
    }
}

extension BrowserTab {
    /// User script injected into every page to mirror the current text
    /// selection back to Swift. Fires on mouseup (the standard moment users
    /// expect a selection menu), tracks `selectionchange` to hide promptly
    /// when the selection collapses, and re-reports on scroll/resize so the
    /// floating widget tracks the highlight.
    static let textSelectionUserScript = WKUserScript(
        source: """
        (() => {
            const HANDLER = '\(TextSelectionBridge.messageName)';
            let lastVisible = false;

            function post(payload) {
                try {
                    window.webkit.messageHandlers[HANDLER].postMessage(payload);
                } catch (_) {}
            }

            function emitHidden() {
                if (!lastVisible) return;
                lastVisible = false;
                post({ visible: false, text: '', x: 0, y: 0, width: 0, height: 0 });
            }

            function reportSelection() {
                const sel = window.getSelection();
                if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
                    emitHidden();
                    return;
                }
                const raw = sel.toString();
                const trimmed = raw.replace(/\\s+/g, ' ').trim();
                if (trimmed.length < 2) {
                    emitHidden();
                    return;
                }
                const range = sel.getRangeAt(0);
                const rect = range.getBoundingClientRect();
                if ((rect.width === 0 && rect.height === 0) ||
                    (rect.left === 0 && rect.top === 0 && rect.right === 0 && rect.bottom === 0)) {
                    return;
                }
                lastVisible = true;
                post({
                    visible: true,
                    text: trimmed.length > 12000 ? trimmed.slice(0, 12000) : trimmed,
                    x: rect.left,
                    y: rect.top,
                    width: rect.width,
                    height: rect.height
                });
            }

            document.addEventListener('mouseup', () => {
                // Let the selection settle before measuring — mouseup fires
                // before the selection finalizes on some pages.
                setTimeout(reportSelection, 12);
            }, true);

            document.addEventListener('selectionchange', () => {
                const sel = window.getSelection();
                if (!sel || sel.isCollapsed) {
                    emitHidden();
                }
            });

            document.addEventListener('keydown', (event) => {
                if (event.key === 'Escape' && lastVisible) {
                    emitHidden();
                }
            }, true);

            let scrollTimer = null;
            window.addEventListener('scroll', () => {
                if (!lastVisible) return;
                if (scrollTimer) clearTimeout(scrollTimer);
                scrollTimer = setTimeout(reportSelection, 16);
            }, true);

            window.addEventListener('resize', () => {
                if (lastVisible) reportSelection();
            }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
}
