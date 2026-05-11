import WebKit

/// Page-side shim that watches focused text fields, debounces the user's
/// keystrokes, asks Swift for a completion, and renders the result as
/// ghost text anchored to the caret. The IIFE is intentionally
/// self-contained — the only global it exposes is `window.__tbInline`, the
/// surface Swift calls into via `evaluateJavaScript`.
enum InlineCompletionsUserScript {
    @MainActor
    static func make() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source: String = #"""
    (() => {
        if (window.__tbInlineLoaded) return;
        window.__tbInlineLoaded = true;

        const MESSAGE = '\#(InlineCompletionsBridge.messageName)';
        const NS = window.__tbInline = window.__tbInline || {};

        let settings = {
            isEnabled: true,
            triggerDelayMs: 600,
            renderMode: 'ghost',
            allowList: [],
            blockList: [],
            isIncognito: false
        };

        let activeTarget = null;
        let pendingTimer = null;
        let currentSuggestion = '';
        let currentSeq = 0;
        let seq = 0;
        let overlayEl = null;
        let mirrorEl = null;
        let lastReadyAt = 0;

        // -------------------------------------------------------------
        // Settings + bridge plumbing
        // -------------------------------------------------------------

        NS.applySettings = (next) => {
            if (!next || typeof next !== 'object') return;
            settings = Object.assign({}, settings, next);
            if (!settings.isEnabled) dismiss();
        };

        NS.deliver = (responseSeq, suggestion, source) => {
            if (responseSeq !== currentSeq) return;
            if (!suggestion) return;
            if (!activeTarget) return;
            const active = document.activeElement;
            if (active !== activeTarget && !(activeTarget.contains && activeTarget.contains(active))) return;
            showSuggestion(suggestion);
        };

        function post(payload) {
            try {
                window.webkit.messageHandlers[MESSAGE].postMessage(payload);
            } catch (_) {}
        }

        function requestSettings() {
            const now = Date.now();
            if (now - lastReadyAt < 1500) return;
            lastReadyAt = now;
            post({ kind: 'ready' });
        }

        // -------------------------------------------------------------
        // Allow / block + element eligibility
        // -------------------------------------------------------------

        function hostMatches(list, host) {
            host = (host || '').toLowerCase();
            if (!host) return false;
            return list.some((entry) => host === entry || host.endsWith('.' + entry));
        }

        function siteAllowed() {
            if (!settings.isEnabled) return false;
            if (settings.isIncognito) return false;
            const host = location.hostname;
            if (hostMatches(settings.blockList, host)) return false;
            if (!settings.allowList || !settings.allowList.length) return true;
            return hostMatches(settings.allowList, host);
        }

        function isEligibleElement(el) {
            if (!el || el.nodeType !== 1) return false;
            const tag = el.tagName;
            if (tag !== 'TEXTAREA' && el.isContentEditable !== true) return false;
            if (el.readOnly === true || el.disabled === true) return false;

            const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
            if (autocomplete === 'one-time-code') return false;
            if (autocomplete.indexOf('cc-') !== -1) return false;
            if (autocomplete === 'new-password' || autocomplete === 'current-password') return false;

            const ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
            const placeholder = (el.getAttribute('placeholder') || '').toLowerCase();
            if (/^\s*search\b/.test(ariaLabel) || /\bsearch\s+(box|field|bar)\b/.test(ariaLabel)) return false;
            if (/^\s*search\s*$/.test(placeholder) || /^\s*search\s/.test(placeholder)) return false;
            if (el.getAttribute('role') === 'searchbox') return false;
            if (el.getAttribute('aria-autocomplete') === 'inline') return false;

            if (document.body && document.body.getAttribute('data-tb-inline-suspend') === '1') return false;
            if (hasActiveCompetingGhost(el)) return false;

            return true;
        }

        /// True when another inline-completion UI (Gmail Smart Compose, etc.)
        /// is currently painting its own ghost text inside this element.
        /// We yield only when we can see the competing UI is active — not
        /// just because the site *could* offer one — so Gmail compose still
        /// gets our completions when Smart Compose stays quiet.
        function hasActiveCompetingGhost(el) {
            if (!el || !el.querySelector) return false;
            // Gmail Smart Compose paints a <span data-smartmail="gmail_smartcompose">.
            if (el.querySelector('[data-smartmail], span.smartcompose-suggestion')) return true;
            // Generic: any descendant span whose aria-label suggests
            // "press Tab to accept" — the universal Smart Compose pattern.
            const candidates = el.querySelectorAll('span[aria-label]');
            for (let i = 0; i < candidates.length; i++) {
                const label = (candidates[i].getAttribute('aria-label') || '').toLowerCase();
                if (label.indexOf('press tab') !== -1 || label.indexOf('tab to accept') !== -1) return true;
            }
            return false;
        }

        // -------------------------------------------------------------
        // Per-site context hints
        // -------------------------------------------------------------

        const SITE_HINTS = [
            {
                match: /(^|\.)mail\.google\.com$/,
                collect: () => {
                    const out = {};
                    const subject = document.querySelector('input[name="subjectbox"]');
                    if (subject && subject.value) out.subject = truncate(subject.value, 160);
                    const recipientNodes = document.querySelectorAll('div[role="region"] [email]');
                    const recipients = Array.prototype.slice.call(recipientNodes)
                        .map((node) => node.getAttribute('email'))
                        .filter(Boolean)
                        .slice(0, 5)
                        .join(', ');
                    if (recipients) out.recipients = recipients;
                    return out;
                }
            },
            {
                match: /(^|\.)github\.com$/,
                collect: () => {
                    const out = {};
                    const title = document.querySelector('.js-issue-title') || document.querySelector('h1.gh-header-title');
                    if (title) out.issueTitle = truncate(title.textContent || '', 200);
                    const ownerRepo = document.querySelector('meta[name="octolytics-dimension-repository_nwo"]');
                    if (ownerRepo && ownerRepo.content) out.repo = ownerRepo.content;
                    const body = document.querySelector('.comment-body, .markdown-body');
                    if (body) out.issueBody = truncate((body.textContent || '').replace(/\s+/g, ' '), 600);
                    return out;
                }
            },
            {
                match: /(^|\.)slack\.com$/,
                collect: () => {
                    const out = {};
                    const header = document.querySelector('[data-qa="channel_name"]');
                    if (header) out.channel = truncate(header.textContent || '', 80);
                    const nodes = document.querySelectorAll('[data-qa="message_text"], .c-message__body');
                    const msgs = Array.prototype.slice.call(nodes, -3)
                        .map((el) => truncate((el.textContent || '').replace(/\s+/g, ' '), 200))
                        .filter(Boolean)
                        .join('\n---\n');
                    if (msgs) out.recentMessages = msgs;
                    return out;
                }
            },
            {
                match: /(^|\.)linear\.app$/,
                collect: () => {
                    const out = {};
                    const title = document.querySelector('[data-testid="issue-title"], .IssueViewHeader h1, h1');
                    if (title) out.ticketTitle = truncate(title.textContent || '', 200);
                    return out;
                }
            },
            {
                match: /(^|\.)notion\.so$/,
                collect: () => {
                    const out = {};
                    const title = document.querySelector('.notion-page-block .notranslate, [placeholder="Untitled"]');
                    if (title) {
                        out.pageTitle = truncate(title.textContent || title.value || '', 200);
                    }
                    return out;
                }
            },
            {
                match: /(^|\.)reddit\.com$/,
                collect: () => {
                    const out = {};
                    const post = document.querySelector('h1');
                    if (post) out.postTitle = truncate(post.textContent || '', 200);
                    return out;
                }
            },
            {
                match: /(^|\.)(x|twitter)\.com$/,
                collect: () => {
                    const out = {};
                    const original = document.querySelector('article[data-testid="tweet"] [data-testid="tweetText"]');
                    if (original) out.replyingTo = truncate(original.textContent || '', 280);
                    return out;
                }
            }
        ];

        function collectSiteHints() {
            const host = location.hostname;
            for (let i = 0; i < SITE_HINTS.length; i++) {
                const rule = SITE_HINTS[i];
                if (rule.match.test(host)) {
                    try { return rule.collect() || {}; } catch (_) { return {}; }
                }
            }
            return {};
        }

        function nearestHeading(el) {
            let cur = el;
            for (let i = 0; i < 6 && cur; i++) {
                if (cur.querySelector) {
                    const heading = cur.querySelector('h1, h2, h3');
                    if (heading) return truncate(heading.textContent || '', 120);
                }
                cur = cur.parentElement;
            }
            const top = document.querySelector('h1');
            return top ? truncate(top.textContent || '', 120) : '';
        }

        function elementLabel(el) {
            const aria = el.getAttribute('aria-label');
            if (aria) return aria;
            const ph = el.getAttribute('placeholder');
            if (ph) return ph;
            if (el.id) {
                let labelEl = null;
                try { labelEl = document.querySelector('label[for="' + cssEscape(el.id) + '"]'); } catch (_) {}
                if (labelEl) return labelEl.textContent || '';
            }
            return '';
        }

        function cssEscape(value) {
            if (window.CSS && CSS.escape) return CSS.escape(value);
            return String(value).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
        }

        function truncate(text, limit) {
            const collapsed = (text || '').replace(/\s+/g, ' ').trim();
            return collapsed.length > limit ? collapsed.slice(0, limit) + '…' : collapsed;
        }

        // -------------------------------------------------------------
        // Context capture (left + right of caret, ≤ ~1.8kB total)
        // -------------------------------------------------------------

        const BEFORE_LIMIT = 1400;
        const AFTER_LIMIT = 400;
        const PAYLOAD_LIMIT = 2048;

        function captureContext(el) {
            let before = '';
            let after = '';
            if (el.tagName === 'TEXTAREA') {
                const start = el.selectionStart;
                const end = el.selectionEnd;
                if (start !== end) return null;
                const value = el.value || '';
                before = value.slice(0, start);
                after = value.slice(end);
            } else if (el.isContentEditable) {
                const sel = window.getSelection();
                if (!sel || sel.rangeCount === 0 || !sel.isCollapsed) return null;
                const range = sel.getRangeAt(0);
                if (!el.contains(range.startContainer)) return null;
                const fullText = el.innerText || '';
                const pre = document.createRange();
                pre.selectNodeContents(el);
                pre.setEnd(range.startContainer, range.startOffset);
                const offset = pre.toString().length;
                before = fullText.slice(0, offset);
                after = fullText.slice(offset);
            } else {
                return null;
            }
            if (before.length > BEFORE_LIMIT) before = before.slice(before.length - BEFORE_LIMIT);
            if (after.length > AFTER_LIMIT) after = after.slice(0, AFTER_LIMIT);
            if (before.length + after.length > PAYLOAD_LIMIT) {
                const slack = PAYLOAD_LIMIT - after.length;
                if (slack > 0 && before.length > slack) before = before.slice(before.length - slack);
            }
            return { before: before, after: after };
        }

        function cacheKey(before, after, hints) {
            const hintsJSON = Object.keys(hints || {}).sort()
                .map((k) => k + ':' + (hints[k] || ''))
                .join('|');
            const tail = before.slice(Math.max(0, before.length - 400));
            const head = after.slice(0, 80);
            return location.hostname + '\u0001' + hintsJSON + '\u0001' + tail + '\u0001' + head;
        }

        // -------------------------------------------------------------
        // Trigger / debounce
        // -------------------------------------------------------------

        function scheduleRequest(immediate) {
            if (!siteAllowed()) return;
            if (!activeTarget || !isEligibleElement(activeTarget)) return;
            if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = null; }
            const delay = immediate ? 0 : Math.max(200, Math.min(2000, settings.triggerDelayMs || 600));
            pendingTimer = setTimeout(fireRequest, delay);
        }

        function fireRequest() {
            pendingTimer = null;
            if (!activeTarget) return;
            const ctx = captureContext(activeTarget);
            if (!ctx) return;
            if (!ctx.before.trim()) return;

            seq += 1;
            const newSeq = seq;
            // Cancel any in-flight request explicitly so Swift can drop it
            // before evaluating; the server-side seq check is the
            // backstop.
            if (currentSeq && currentSeq !== newSeq) {
                post({ kind: 'cancel', requestSeq: currentSeq });
            }
            currentSeq = newSeq;
            if (currentSuggestion) {
                hideOverlay();
                currentSuggestion = '';
            }

            const hints = collectSiteHints();
            post({
                kind: 'request',
                requestSeq: newSeq,
                cacheKey: cacheKey(ctx.before, ctx.after, hints),
                host: location.hostname,
                title: document.title || '',
                elementKind: activeTarget.tagName === 'TEXTAREA' ? 'textarea' : 'contenteditable',
                elementLabel: elementLabel(activeTarget),
                nearestHeading: nearestHeading(activeTarget),
                siteHints: hints,
                textBefore: ctx.before,
                textAfter: ctx.after
            });
        }

        function lastCharIsSentenceEnder() {
            if (!activeTarget) return false;
            const ctx = captureContext(activeTarget);
            if (!ctx) return false;
            const lastChar = ctx.before.slice(-1);
            return lastChar === '.' || lastChar === '?' || lastChar === '!' || lastChar === ':';
        }

        // -------------------------------------------------------------
        // Ghost overlay rendering
        // -------------------------------------------------------------

        function ensureOverlay() {
            if (overlayEl && document.body && document.body.contains(overlayEl)) return overlayEl;
            overlayEl = document.createElement('span');
            overlayEl.setAttribute('data-tb-inline-overlay', '1');
            overlayEl.style.cssText = [
                'position:absolute',
                'pointer-events:none',
                'z-index:2147483646',
                'color:rgba(180,180,180,0.65)',
                'background:transparent',
                'font:inherit',
                'white-space:pre',
                'padding:0',
                'margin:0',
                'border:0',
                'max-width:90vw',
                'overflow:hidden',
                'text-overflow:ellipsis'
            ].join(';');
            (document.body || document.documentElement).appendChild(overlayEl);
            return overlayEl;
        }

        function disposeMirror() {
            if (mirrorEl && mirrorEl.parentNode) mirrorEl.parentNode.removeChild(mirrorEl);
            mirrorEl = null;
        }

        function caretRectForTextarea(el) {
            const cs = getComputedStyle(el);
            if (!mirrorEl) {
                mirrorEl = document.createElement('div');
                (document.body || document.documentElement).appendChild(mirrorEl);
            }
            const props = [
                'boxSizing','width','height','overflowX','overflowY',
                'borderTopWidth','borderRightWidth','borderBottomWidth','borderLeftWidth',
                'paddingTop','paddingRight','paddingBottom','paddingLeft',
                'fontStyle','fontVariant','fontWeight','fontStretch','fontSize','fontSizeAdjust',
                'lineHeight','fontFamily','textAlign','textTransform','textIndent','textDecoration',
                'letterSpacing','wordSpacing','tabSize','direction','whiteSpace','wordWrap'
            ];
            for (let i = 0; i < props.length; i++) {
                try { mirrorEl.style[props[i]] = cs[props[i]]; } catch (_) {}
            }
            mirrorEl.style.position = 'absolute';
            mirrorEl.style.top = '-9999px';
            mirrorEl.style.left = '-9999px';
            mirrorEl.style.visibility = 'hidden';
            mirrorEl.style.whiteSpace = 'pre-wrap';
            mirrorEl.style.wordWrap = 'break-word';
            mirrorEl.style.overflow = 'hidden';

            const value = (el.value || '').slice(0, el.selectionStart);
            mirrorEl.textContent = value;
            const marker = document.createElement('span');
            marker.textContent = '​';
            mirrorEl.appendChild(marker);
            const mirrorRect = mirrorEl.getBoundingClientRect();
            const markerRect = marker.getBoundingClientRect();
            const elRect = el.getBoundingClientRect();
            return {
                left: elRect.left + (markerRect.left - mirrorRect.left) - el.scrollLeft,
                top: elRect.top + (markerRect.top - mirrorRect.top) - el.scrollTop,
                lineHeight: parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) || 16
            };
        }

        function caretRectForContenteditable() {
            const sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) return null;
            const range = sel.getRangeAt(0).cloneRange();
            range.collapse(true);
            let rect = range.getBoundingClientRect();
            if (rect && (rect.width || rect.height || rect.left || rect.top)) {
                return { left: rect.left, top: rect.top, lineHeight: rect.height || 18 };
            }
            const marker = document.createElement('span');
            marker.appendChild(document.createTextNode('​'));
            try {
                range.insertNode(marker);
                rect = marker.getBoundingClientRect();
            } finally {
                if (marker.parentNode) marker.parentNode.removeChild(marker);
            }
            return rect ? { left: rect.left, top: rect.top, lineHeight: rect.height || 18 } : null;
        }

        function showSuggestion(text) {
            if (!activeTarget || !text) return;
            currentSuggestion = text;
            const overlay = ensureOverlay();
            const isTextarea = activeTarget.tagName === 'TEXTAREA';
            let rect = null;
            try {
                rect = isTextarea ? caretRectForTextarea(activeTarget) : caretRectForContenteditable();
            } catch (_) {
                rect = null;
            }
            if (!rect) { hideOverlay(); return; }
            const cs = getComputedStyle(activeTarget);
            overlay.style.font = cs.font;
            overlay.style.fontFamily = cs.fontFamily;
            overlay.style.fontSize = cs.fontSize;
            overlay.style.lineHeight = cs.lineHeight;
            overlay.style.left = (window.scrollX + rect.left) + 'px';

            if (settings.renderMode === 'popover') {
                overlay.style.background = 'rgba(20,20,20,0.92)';
                overlay.style.color = 'rgba(220,220,220,0.96)';
                overlay.style.padding = '5px 9px';
                overlay.style.borderRadius = '6px';
                overlay.style.boxShadow = '0 6px 20px rgba(0,0,0,0.35)';
                overlay.style.fontSize = '12px';
                overlay.style.font = '';
                overlay.style.top = (window.scrollY + rect.top + rect.lineHeight + 4) + 'px';
                overlay.textContent = text + '   ⇥ accept · esc dismiss';
            } else {
                overlay.style.background = 'transparent';
                overlay.style.color = 'rgba(180,180,180,0.65)';
                overlay.style.padding = '0';
                overlay.style.borderRadius = '0';
                overlay.style.boxShadow = 'none';
                overlay.style.top = (window.scrollY + rect.top) + 'px';
                overlay.textContent = text;
            }
        }

        function hideOverlay() {
            if (overlayEl) {
                overlayEl.textContent = '';
                overlayEl.style.background = 'transparent';
                overlayEl.style.boxShadow = 'none';
                overlayEl.style.padding = '0';
            }
            disposeMirror();
        }

        function dismiss() {
            if (currentSeq) post({ kind: 'cancel', requestSeq: currentSeq });
            currentSuggestion = '';
            if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = null; }
            hideOverlay();
        }

        // -------------------------------------------------------------
        // Insertion (Tab / ⌘→)
        // -------------------------------------------------------------

        function insertText(el, text) {
            if (!text) return;
            const tag = el.tagName;
            if (tag === 'TEXTAREA' || tag === 'INPUT') {
                try {
                    const proto = tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                    const start = el.selectionStart;
                    const end = el.selectionEnd;
                    const next = (el.value || '').slice(0, start) + text + (el.value || '').slice(end);
                    setter.call(el, next);
                    const cursor = start + text.length;
                    el.selectionStart = el.selectionEnd = cursor;
                    el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
                    return;
                } catch (_) {}
            }
            try {
                if (document.execCommand('insertText', false, text)) return;
            } catch (_) {}
            const sel = window.getSelection();
            if (sel && sel.rangeCount > 0) {
                const range = sel.getRangeAt(0);
                range.deleteContents();
                range.insertNode(document.createTextNode(text));
                range.collapse(false);
                sel.removeAllRanges();
                sel.addRange(range);
                el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            }
        }

        function acceptFull() {
            if (!currentSuggestion || !activeTarget) return;
            const text = currentSuggestion;
            currentSuggestion = '';
            hideOverlay();
            insertText(activeTarget, text);
        }

        function acceptWord() {
            if (!currentSuggestion || !activeTarget) return;
            const match = currentSuggestion.match(/^\s*\S+\s?/);
            if (!match) { acceptFull(); return; }
            const piece = match[0];
            insertText(activeTarget, piece);
            const remaining = currentSuggestion.slice(piece.length);
            currentSuggestion = remaining;
            if (remaining) {
                requestAnimationFrame(() => showSuggestion(remaining));
            } else {
                hideOverlay();
            }
        }

        // -------------------------------------------------------------
        // Event wiring
        // -------------------------------------------------------------

        document.addEventListener('keydown', (event) => {
            if (!activeTarget) return;
            if (currentSuggestion) {
                if (event.key === 'Tab' && !event.shiftKey && !event.ctrlKey && !event.altKey) {
                    event.preventDefault();
                    event.stopPropagation();
                    acceptFull();
                    return;
                }
                if (event.key === 'ArrowRight' && event.metaKey) {
                    event.preventDefault();
                    event.stopPropagation();
                    acceptWord();
                    return;
                }
                if (event.key === 'Escape') {
                    event.preventDefault();
                    event.stopPropagation();
                    dismiss();
                    return;
                }
            }
            handleTypingForTrigger(event);
        }, true);

        function handleTypingForTrigger(event) {
            if (event.ctrlKey || event.altKey) return;
            if (event.metaKey && event.key !== 'Backspace') return;
            if (event.key === 'Shift' || event.key === 'Meta' || event.key === 'Control' || event.key === 'Alt') return;

            if (currentSuggestion && event.key && event.key.length === 1 && !event.metaKey) {
                if (currentSuggestion[0] === event.key) {
                    const remaining = currentSuggestion.slice(1);
                    currentSuggestion = remaining;
                    if (remaining) {
                        requestAnimationFrame(() => showSuggestion(remaining));
                    } else {
                        hideOverlay();
                    }
                    return;
                }
                dismiss();
            } else if (currentSuggestion && (event.key === 'Backspace' || event.key === 'Delete')) {
                dismiss();
            }

            if (event.key === 'Enter') {
                dismiss();
                scheduleRequest(true);
                return;
            }
            if (event.key === ' ' && lastCharIsSentenceEnder()) {
                scheduleRequest(true);
                return;
            }
            scheduleRequest(false);
        }

        document.addEventListener('focusin', (event) => {
            const target = event.target;
            if (!isEligibleElement(target)) {
                activeTarget = null;
                dismiss();
                return;
            }
            activeTarget = target;
            requestSettings();
        }, true);

        document.addEventListener('focusout', () => {
            activeTarget = null;
            dismiss();
        }, true);

        document.addEventListener('mousedown', (event) => {
            // Click on the suggestion overlay itself shouldn't dismiss —
            // but `pointer-events:none` keeps the overlay from receiving
            // clicks anyway, so any mousedown means the user moved on.
            if (event.target && event.target.getAttribute && event.target.getAttribute('data-tb-inline-overlay') === '1') {
                return;
            }
            dismiss();
        }, true);

        document.addEventListener('selectionchange', () => {
            if (!activeTarget || !currentSuggestion) return;
            const sel = window.getSelection();
            if (!sel) return;
            if (!sel.isCollapsed) { dismiss(); return; }
            if (sel.anchorNode && activeTarget.contains && !activeTarget.contains(sel.anchorNode)) {
                dismiss();
            }
        });

        window.addEventListener('scroll', () => {
            if (currentSuggestion) showSuggestion(currentSuggestion);
        }, true);

        window.addEventListener('resize', () => {
            if (currentSuggestion) showSuggestion(currentSuggestion);
        });

        // Smart Compose etc. attach asynchronously — re-check eligibility
        // periodically so we don't keep firing on a field that just grew
        // a competing UI.
        setInterval(() => {
            if (activeTarget && !isEligibleElement(activeTarget)) {
                activeTarget = null;
                dismiss();
            }
        }, 1500);

        requestSettings();
    })();
    """#
}
