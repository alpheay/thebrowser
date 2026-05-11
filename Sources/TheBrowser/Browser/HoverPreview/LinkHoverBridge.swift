import AppKit
import Foundation
@preconcurrency import WebKit

/// One observation reported by the in-page link-hover script. Coordinates
/// are CSS pixels relative to the visible viewport — same convention as
/// ``TextSelectionInfo``, which lets the SwiftUI overlay measure both
/// widgets in the same coordinate space.
struct LinkHoverInfo: Equatable {
    enum Kind: Equatable {
        case peek
        case prefetch
        case rect
        case leave
    }

    var kind: Kind
    var url: URL?
    var title: String
    var rect: CGRect
    var sameOrigin: Bool
    var isAnchorOnly: Bool
}

/// JS → Swift handler for the link-hover user script. Mirrors
/// ``TextSelectionBridge`` so both bridges look the same to the tab.
final class LinkHoverBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    static let messageName = "thebrowserLinkHover"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let kindString = body["kind"] as? String,
              let kind = parseKind(kindString) else {
            return
        }

        let urlString = body["url"] as? String ?? ""
        let url = URL(string: urlString)
        let title = body["title"] as? String ?? ""
        let x = (body["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (body["y"] as? NSNumber)?.doubleValue ?? 0
        let width = (body["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (body["height"] as? NSNumber)?.doubleValue ?? 0
        let sameOrigin = body["sameOrigin"] as? Bool ?? false
        let isAnchorOnly = body["isAnchorOnly"] as? Bool ?? false

        let info = LinkHoverInfo(
            kind: kind,
            url: url,
            title: title,
            rect: CGRect(x: x, y: y, width: width, height: height),
            sameOrigin: sameOrigin,
            isAnchorOnly: isAnchorOnly
        )

        Task { @MainActor [weak tab] in
            tab?.applyLinkHover(info)
        }
    }

    private func parseKind(_ string: String) -> LinkHoverInfo.Kind? {
        switch string {
        case "peek": return .peek
        case "prefetch": return .prefetch
        case "rect": return .rect
        case "leave": return .leave
        default: return nil
        }
    }
}

extension BrowserTab {
    /// Builds the link-hover user script with the current user preferences
    /// baked in. Settings changes take effect for tabs opened after the
    /// change; live updates would require an evaluateJavaScript round-trip
    /// per existing tab, which isn't worth the wiring for a v1.
    static func makeLinkHoverUserScript(defaults: UserDefaults = .standard) -> WKUserScript {
        let enabled = defaults.object(forKey: PreferenceKey.hoverPreviewEnabled) as? Bool ?? true
        let modifierString = defaults.string(forKey: PreferenceKey.hoverPreviewModifier)
            ?? HoverPreviewModifier.command.rawValue
        let modifier = HoverPreviewModifier(rawValue: modifierString) ?? .command
        let hoverDelay = defaults.integer(forKey: PreferenceKey.hoverPreviewDelayMs)
        let prefetchDelay = defaults.integer(forKey: PreferenceKey.hoverPreviewPrefetchDelayMs)

        let resolvedHoverDelay = hoverDelay > 0 ? hoverDelay : 200
        let resolvedPrefetchDelay = prefetchDelay > 0 ? prefetchDelay : 800

        let modifierKeysJS = "[" + modifier.domKeyNames
            .map { "'\($0)'" }
            .joined(separator: ", ") + "]"

        let source = """
        (() => {
            const HANDLER = '\(LinkHoverBridge.messageName)';
            const MODIFIER_PROP = '\(modifier.domEventProperty)';
            const MODIFIER_KEYS = \(modifierKeysJS);
            const HOVER_DELAY_MS = \(resolvedHoverDelay);
            const PREFETCH_DELAY_MS = \(resolvedPrefetchDelay);
            let enabled = \(enabled ? "true" : "false");

            // Light per-page state. The closure also exposes setters on a
            // global so Swift can flip enabled at runtime without reloading.
            let currentLink = null;
            let currentURL = null;
            let peekTimer = null;
            let prefetchTimer = null;
            let modifierHeld = false;
            let activeURL = null;
            const prefetched = new Set();

            function post(payload) {
                try {
                    window.webkit.messageHandlers[HANDLER].postMessage(payload);
                } catch (_) {}
            }

            function clearTimers() {
                if (peekTimer) { clearTimeout(peekTimer); peekTimer = null; }
                if (prefetchTimer) { clearTimeout(prefetchTimer); prefetchTimer = null; }
            }

            function rectOf(link) {
                const r = link.getBoundingClientRect();
                return { x: r.left, y: r.top, width: r.width, height: r.height };
            }

            function absoluteURL(link) {
                try {
                    return new URL(link.getAttribute('href'), document.baseURI).href;
                } catch (_) { return link.href || ''; }
            }

            function isAnchorOnly(href) {
                try {
                    const u = new URL(href);
                    const here = new URL(location.href);
                    return u.origin === here.origin
                        && u.pathname === here.pathname
                        && u.search === here.search;
                } catch (_) { return false; }
            }

            function sameOrigin(href) {
                try { return new URL(href).origin === location.origin; }
                catch (_) { return false; }
            }

            function postPeek(link, url) {
                if (!url || isAnchorOnly(url)) return;
                const r = rectOf(link);
                activeURL = url;
                post({
                    kind: 'peek',
                    url,
                    title: (link.getAttribute('title') || (link.textContent || '').trim()).slice(0, 200),
                    x: r.x, y: r.y, width: r.width, height: r.height,
                    sameOrigin: sameOrigin(url),
                    isAnchorOnly: false
                });
            }

            function postPrefetch(url) {
                if (!url || isAnchorOnly(url) || prefetched.has(url)) return;
                prefetched.add(url);
                post({ kind: 'prefetch', url });
            }

            function postLeave(url) {
                if (!url) return;
                if (activeURL === url) activeURL = null;
                post({ kind: 'leave', url });
            }

            function postRect(url, link) {
                if (!url) return;
                const r = rectOf(link);
                post({ kind: 'rect', url, x: r.x, y: r.y, width: r.width, height: r.height });
            }

            function schedule() {
                clearTimers();
                if (!enabled || !currentLink || !currentURL) return;
                if (modifierHeld) {
                    peekTimer = setTimeout(() => {
                        if (!currentLink || !currentURL) return;
                        postPeek(currentLink, currentURL);
                    }, HOVER_DELAY_MS);
                } else {
                    prefetchTimer = setTimeout(() => {
                        if (!currentURL) return;
                        postPrefetch(currentURL);
                    }, PREFETCH_DELAY_MS);
                }
            }

            document.addEventListener('pointerover', (e) => {
                if (!enabled) return;
                const t = e.target;
                if (!t || !t.closest) return;
                const link = t.closest('a[href]');
                if (!link) return;
                if (link === currentLink) return;
                const wasURL = activeURL;
                currentLink = link;
                currentURL = absoluteURL(link);
                modifierHeld = !!(e[MODIFIER_PROP]);
                schedule();
                // Hovered onto a new link while the panel was up for an old
                // one — let Swift know so it can swap content without tearing
                // the panel down (the upcoming `peek` carries the new URL).
                if (wasURL && wasURL !== currentURL && !modifierHeld) {
                    postLeave(wasURL);
                }
            }, true);

            document.addEventListener('pointerout', (e) => {
                if (!enabled) return;
                const link = currentLink;
                if (!link) return;
                const into = e.relatedTarget && e.relatedTarget.closest
                    ? e.relatedTarget.closest('a[href]')
                    : null;
                if (into === link) return;
                clearTimers();
                const wasURL = currentURL;
                currentLink = null;
                currentURL = null;
                if (wasURL) postLeave(wasURL);
            }, true);

            document.addEventListener('keydown', (e) => {
                if (!enabled) return;
                if (!MODIFIER_KEYS.includes((e.key || '').toLowerCase())) return;
                if (modifierHeld) return;
                modifierHeld = true;
                if (currentLink) schedule();
            }, true);

            document.addEventListener('keyup', (e) => {
                if (!enabled) return;
                if (!MODIFIER_KEYS.includes((e.key || '').toLowerCase())) return;
                modifierHeld = false;
                if (currentLink) schedule();
            }, true);

            let scrollDebounce = null;
            function onScrollOrResize() {
                if (!enabled) return;
                if (!activeURL || !currentLink) return;
                if (scrollDebounce) clearTimeout(scrollDebounce);
                scrollDebounce = setTimeout(() => {
                    if (!activeURL || !currentLink) return;
                    postRect(activeURL, currentLink);
                }, 16);
            }
            window.addEventListener('scroll', onScrollOrResize, true);
            window.addEventListener('resize', onScrollOrResize, true);

            // Tiny live-update surface so Swift can disable the bridge for an
            // already-loaded tab without re-injecting the user script.
            window.__theBrowserHoverPreview = {
                setEnabled(value) {
                    enabled = !!value;
                    if (!enabled) { clearTimers(); }
                }
            };
        })();
        """

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}
