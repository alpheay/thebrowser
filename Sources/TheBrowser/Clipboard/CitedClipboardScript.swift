import Foundation
@preconcurrency import WebKit

/// Injects a JS-side copy hook into every frame of every tab. Owns the
/// pasteboard write through `event.preventDefault()` so the resulting
/// pasteboard always carries a consistent set of representations
/// (`text/plain`, augmented `text/html`, and our custom JSON UTI).
///
/// MainActor-isolated to satisfy WKUserScript's strict-concurrency
/// requirements. The other in-tree user scripts dodge this by living on
/// the already-MainActor `BrowserTab`; we're a free-floating namespace, so
/// the annotation goes here.
@MainActor
enum CitedClipboardScript {
    /// Custom MIME type that flows through to NSPasteboard as a matching
    /// custom UTI. Mirrors the spec's `com.thebrowser.cited` identifier.
    nonisolated static let customMIMEType = "com.thebrowser.cited"

    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let source = """
    (() => {
        const HANDLER = '\(CitedClipboardBridge.messageName)';
        const CITED_MIME = '\(CitedClipboardScript.customMIMEType)';

        // Block enrichment when the selection lives inside a sensitive
        // input — password fields, credit-card autocomplete fields, or
        // forms whose autocomplete attribute names a sensitive field.
        const SENSITIVE_AUTOCOMPLETE = new Set([
            'cc-number', 'cc-csc', 'cc-exp', 'cc-exp-month', 'cc-exp-year',
            'cc-name', 'cc-type', 'one-time-code', 'current-password',
            'new-password'
        ]);

        function isSensitiveElement(el) {
            if (!el) return false;
            if (el.tagName === 'INPUT' && el.type === 'password') return true;
            const auto = (el.getAttribute && el.getAttribute('autocomplete') || '').toLowerCase();
            if (SENSITIVE_AUTOCOMPLETE.has(auto)) return true;
            // Inherit sensitivity from the closest enclosing form.
            const form = el.closest && el.closest('form');
            if (form) {
                const formAuto = (form.getAttribute('autocomplete') || '').toLowerCase();
                if (SENSITIVE_AUTOCOMPLETE.has(formAuto)) return true;
            }
            return false;
        }

        function selectionContainsSensitive(sel) {
            if (!sel || sel.rangeCount === 0) return false;
            const range = sel.getRangeAt(0);
            let node = range.commonAncestorContainer;
            if (node && node.nodeType === Node.TEXT_NODE) node = node.parentElement;
            while (node) {
                if (isSensitiveElement(node)) return true;
                node = node.parentElement;
            }
            return false;
        }

        function htmlForRange(range) {
            try {
                const fragment = range.cloneContents();
                const wrapper = document.createElement('div');
                wrapper.appendChild(fragment);
                return wrapper.innerHTML;
            } catch (_) {
                return '';
            }
        }

        // Extract a sentence-clipped snippet of the surrounding text on a
        // single side. `direction` is -1 for "before" and +1 for "after".
        function snippet(text, anchorIndex, direction, maxLength) {
            if (anchorIndex < 0 || anchorIndex > text.length) return '';
            const start = direction < 0 ? Math.max(0, anchorIndex - maxLength) : anchorIndex;
            const end = direction < 0 ? anchorIndex : Math.min(text.length, anchorIndex + maxLength);
            let slice = text.slice(start, end).replace(/\\s+/g, ' ').trim();
            // Sentence-clip: keep up to the nearest sentence boundary on the
            // opposite side from the selection so the snippet feels complete.
            if (direction < 0) {
                const lastBoundary = Math.max(slice.lastIndexOf('. '), slice.lastIndexOf('! '), slice.lastIndexOf('? '));
                if (lastBoundary > 0) slice = slice.slice(lastBoundary + 2);
            } else {
                const firstBoundary = (() => {
                    const candidates = [slice.indexOf('. '), slice.indexOf('! '), slice.indexOf('? ')]
                        .filter((i) => i > 0);
                    return candidates.length ? Math.min.apply(null, candidates) + 1 : -1;
                })();
                if (firstBoundary > 0) slice = slice.slice(0, firstBoundary + 1);
            }
            return slice.trim();
        }

        function surroundingSentences(range, selectedText) {
            try {
                let block = range.startContainer;
                if (block && block.nodeType === Node.TEXT_NODE) block = block.parentElement;
                while (block && block !== document.body) {
                    const display = window.getComputedStyle(block).display;
                    if (display === 'block' || display === 'list-item' || display === 'flex' || display === 'grid' || display === 'table-cell') break;
                    block = block.parentElement;
                }
                if (!block) return { before: '', after: '' };
                const parentText = (block.innerText || block.textContent || '').replace(/\\s+/g, ' ');
                const trimmedSel = selectedText.replace(/\\s+/g, ' ').trim();
                const idx = trimmedSel ? parentText.indexOf(trimmedSel) : -1;
                if (idx < 0) return { before: '', after: '' };
                return {
                    before: snippet(parentText, idx, -1, 140),
                    after: snippet(parentText, idx + trimmedSel.length, 1, 140)
                };
            } catch (_) {
                return { before: '', after: '' };
            }
        }

        function send(payload) {
            try {
                window.webkit.messageHandlers[HANDLER].postMessage(payload);
            } catch (_) {}
        }

        document.addEventListener('copy', (event) => {
            try {
                const selection = window.getSelection();
                if (!selection || selection.isCollapsed || selection.rangeCount === 0) return;
                const rawText = selection.toString();
                const trimmed = rawText.replace(/\\s+/g, ' ').trim();
                if (trimmed.length < 2) return;

                if (selectionContainsSensitive(selection)) {
                    // Let the browser's default copy proceed without
                    // enrichment — and don't post anything to Swift.
                    return;
                }

                const range = selection.getRangeAt(0);
                const html = htmlForRange(range);
                const surround = surroundingSentences(range, rawText);

                const payload = {
                    text: rawText,
                    html: html,
                    sentenceBefore: surround.before,
                    sentenceAfter: surround.after,
                    pageHref: location.href,
                    pageTitle: document.title || '',
                    capturedAt: new Date().toISOString()
                };

                event.preventDefault();
                if (event.clipboardData) {
                    event.clipboardData.setData('text/plain', rawText);
                    if (html) event.clipboardData.setData('text/html', wrapHTMLWithCitation(html, location.href, document.title || ''));
                    try {
                        event.clipboardData.setData(CITED_MIME, JSON.stringify(payload));
                    } catch (_) {}
                }

                send(payload);
            } catch (_) {
                // Fail open: the browser's default copy still runs because
                // we didn't preventDefault before throwing.
            }
        }, true);

        function wrapHTMLWithCitation(innerHTML, url, title) {
            const safeURL = (url || '').replace(/"/g, '&quot;');
            const safeTitle = (title || '').replace(/"/g, '&quot;');
            // The `<meta>` tag is hidden from rendering; receivers that
            // parse the full HTML can pick it up.
            return [
                '<meta data-source-url="' + safeURL + '" data-source-title="' + safeTitle + '">',
                '<div data-cited-clipboard data-source-url="' + safeURL + '" data-source-title="' + safeTitle + '">',
                innerHTML,
                '</div>'
            ].join('');
        }
    })();
    """
}
