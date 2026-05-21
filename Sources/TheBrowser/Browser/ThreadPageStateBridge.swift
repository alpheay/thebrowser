import Foundation
@preconcurrency import WebKit

final class ThreadPageStateBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    static let messageName = "thebrowserPageStateChanged"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName else { return }
        Task { @MainActor [weak tab] in
            tab?.notifyPageInteractionChanged()
        }
    }
}

extension BrowserTab {
    static let pageStateUserScript = WKUserScript(
        source: """
        (() => {
            const HANDLER = '\(ThreadPageStateBridge.messageName)';
            let timer = null;

            function post() {
                try {
                    window.webkit.messageHandlers[HANDLER].postMessage({ changed: true });
                } catch (_) {}
            }

            function schedule() {
                if (timer) clearTimeout(timer);
                timer = setTimeout(post, 80);
            }

            window.addEventListener('scroll', schedule, { passive: true, capture: true });
            window.addEventListener('resize', schedule, { passive: true });
            document.addEventListener('input', schedule, true);
            document.addEventListener('change', schedule, true);

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            history.pushState = function() {
                const result = originalPushState.apply(this, arguments);
                schedule();
                return result;
            };
            history.replaceState = function() {
                const result = originalReplaceState.apply(this, arguments);
                schedule();
                return result;
            };
            window.addEventListener('popstate', schedule, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
}
