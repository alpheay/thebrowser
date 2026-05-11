# Cited Clipboard

Design notes for the capture-on-copy + smart-paste feature. Companion to the
implementation under `Sources/TheBrowser/Clipboard/`.

## Goal

Whenever the user copies text from a web page, preserve where it came from —
URL, page title, surrounding sentence, copy timestamp — so that pasting it
elsewhere can be done with attribution. The default plain-text rep stays
unchanged so paste behavior in unknown apps is identical to today (zero
friction). Markdown- and rich-text-aware destinations get a citation rewrite
when the user pastes.

## Capture pipeline

`copy` events on web pages flow through a JS hook injected as a `WKUserScript`
at document start, on every frame (so iframe selections are captured too).
The hook:

1. Builds the payload synchronously inside the JS event handler:
   - `text` — the selection's plain text (collapsed whitespace, trimmed).
   - `html` — `selection.getRangeAt(0).cloneContents()` serialized to HTML.
   - `sentenceBefore` / `sentenceAfter` — up to 140 chars on each side of the
     selection inside its parent block element, sentence-clipped.
   - `isSensitive` — true if the active element is a password field, has
     `autocomplete=cc-number`/`cc-csc`, or sits inside a form whose
     `autocomplete` says so. The handler bails out without enriching when
     this is true.
2. Calls `event.preventDefault()` and writes all reps via
   `event.clipboardData.setData(...)`:
   - `text/plain` — the selection text (unchanged, no citation).
   - `text/html` — original selection HTML wrapped in a `<div data-source-url
     data-source-title>` and followed by a hidden `<meta data-source>` block.
   - `text/com.thebrowser.cited+json` — the full JSON payload.
3. `postMessage`s the payload to Swift via
   `webkit.messageHandlers.thebrowserCitedClipboard`.

The bridge on the Swift side (`CitedClipboardBridge`) receives the payload and
hands it to `CitedClipboardController`, which:

- Resolves source URL / title / domain from the owning `BrowserTab` (not from
  any URL the JS may have computed — this is iframe-safe and immune to script
  spoofing).
- Persists a `CitedClip` to the SQLite log if capture is enabled and the
  domain isn't on the blocklist.
- Records the pasteboard `changeCount` for smart-paste ownership tracking.

The JS preventDefault means we own the pasteboard write entirely. The default
WebKit copy never happens, so there's no race with our enrichment.

## Storage schema

`~/.thebrowser/clipboard.sqlite`, accessed via the system `libsqlite3` (no
external dependency, no SwiftPM target). Single connection, MainActor-bound,
matching `ChatSessionStore`'s threading model.

```sql
CREATE TABLE IF NOT EXISTS clips (
  id                     TEXT PRIMARY KEY,
  text                   TEXT NOT NULL,
  source_url             TEXT NOT NULL DEFAULT '',
  source_title           TEXT NOT NULL DEFAULT '',
  page_domain            TEXT NOT NULL DEFAULT '',
  timestamp_iso          TEXT NOT NULL,
  sentence_before        TEXT NOT NULL DEFAULT '',
  sentence_after         TEXT NOT NULL DEFAULT '',
  copied_from_tab_title  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS clips_ts ON clips (timestamp_iso DESC);
```

After each insert, prune anything beyond the 200 newest entries:

```sql
DELETE FROM clips WHERE id IN (
  SELECT id FROM clips ORDER BY timestamp_iso DESC LIMIT -1 OFFSET 200
);
```

Local-only. Never synced. The store lives at the same `~/.thebrowser/` root as
chat sessions and artifacts.

## Paste interception strategy

The original spec mentions an "accessibility-API helper" — but the same
behavior is achievable without requesting accessibility, via NSWorkspace's
app-activation notifications. We do that.

`CitedPasteRewriter` listens for
`NSWorkspace.didActivateApplicationNotification`. On each activation:

1. If smart-paste is disabled, return.
2. Read the pasteboard's `changeCount`. If it doesn't match the count we
   recorded when we last wrote, the user has copied something new — give up
   ownership and stop touching it for this clip.
3. If it does match, look up the activated app's bundle ID against the
   per-app rules:
   - Markdown apps (Obsidian, iA Writer, Bear, Notion desktop, Logseq,
     Typora) → rewrite the `public.utf8-plain-text` rep to either
     `> {quote}\n\n— [{title}]({url})` (blockquote, default) or
     `[{quote}]({url})` (inline), based on the user's format preference.
   - Rich-text apps (Apple Notes, Mail, Pages, TextEdit) → leave plain text
     alone; the existing `public.html` rep with the citation footer already
     wins for their paste handler.
   - Unknown apps → no rewrite (zero-friction default).
4. After rewriting, capture the new `changeCount` so subsequent activations
   keep recognizing our ownership across rewrites.

Switching back to TheBrowser doesn't trigger a rewrite — we only act on
*other* apps becoming frontmost.

If the user copies in another app, `changeCount` advances and we lose
ownership. We never modify a pasteboard we didn't write.

The accessibility permission isn't requested at all in v1. If we later want
to *trigger* the host app's paste keystroke (rather than relying on the user
pressing ⌘V), that's the point we'd ask for it — and degrade to "Copied —
press ⌘V to paste" when denied.

## Popover UX (⌘⇧V)

Configurable via Settings → Keybindings (default `command+shift+v`,
verified non-conflicting with the existing chord set). Local shortcut for
v1 — fires only while TheBrowser is frontmost.

The popover anchors to a small clipboard icon in the toolbar (so it has a
stable visual origin). Layout, top-down:

- Search field (filters by clip text or source domain).
- Scrollable list of recent clips (newest first), each row:
  - Single-line preview of the clip text.
  - Source: domain + relative timestamp ("github.com · 2m ago").
  - On hover: a small "Re-copy" affordance.
- Selecting a clip swaps the list for a format submenu:
  - Markdown blockquote — `> {quote}\n\n— [{title}]({url})`
  - Markdown inline — `[{quote}]({url})`
  - Footnote — `{quote}[^1]` plus `[^1]: {title} — {url}` after.
  - APA — `"{quote}" ({author/site}, {year}). Retrieved from {url}`
    (author falls back to domain when not known).
  - Quote block — `"{quote}" — {title} ({url})`
  - Plain — just `{quote}`, no citation.
- Picking a format writes that exact text to NSPasteboard and dismisses the
  popover. A toast confirms "Copied — switch and paste".

The manual flow always overrides smart-paste rewriting: when the user picks
a format, the controller marks the resulting pasteboard write as
"manually formatted", and the rewriter skips it on subsequent activations.

## Settings

New "Clipboard" tab in Settings:

- **Master toggle** "Enable Cited Clipboard" (default ON).
- **Format preferences**:
  - Markdown style (segmented): blockquote / inline.
  - Citation style (segmented): bracketed link / footnote.
- **Smart paste destinations** (segmented): on / off.
- **Domain blocklist** (multiline): one host per line. Default ships a small
  starter list of obviously sensitive domains (banking + healthcare). Match
  is suffix-based (`bankofamerica.com` matches `secure.bankofamerica.com`).
- **Per-app overrides**: list of `bundleID → format` rows, each with a
  delete button.
- **Recent clips** (scrolling list), each row: text preview, source URL,
  timestamp, "Re-copy" button, delete button. "Clear all" header action.

## Privacy & safety

- **Incognito tabs**: not in the codebase yet. `BrowserTab.allowsClipboardCapture`
  defaults to true; when incognito ships, that flag should flip to false.
- **Domain blocklist**: starter list defined in `CitedClipboardPolicy`. Matched
  against the tab's host with suffix semantics. Blocked domains never write
  the custom JSON rep, never persist a clip, and never get their plain-text
  rewritten on smart-paste.
- **Sensitive inputs**: detected JS-side from the active element / its
  ancestor form. If the selection sits inside one, we skip enrichment and
  let the system do its default copy.
- **Local-only persistence**: SQLite at `~/.thebrowser/clipboard.sqlite`.
  Never synced. "Clear all" wipes it; per-row delete works too.

## Edge cases

- **PDF in WebKit**: WKWebView renders PDFs without a JS-injectable DOM, so
  the JS hook doesn't run. v1 falls through to the system clipboard with no
  enrichment — known limitation noted in code (the spec calls for PDFKit
  page numbers; deferred to follow-up).
- **iframes**: the JS hook runs in every frame (`forMainFrameOnly: false`).
  The bridge ignores any URL the JS sends and uses the owning tab's URL
  instead, so cross-origin iframe selections still attribute to the parent
  page.
- **Multi-paragraph selections**: stored verbatim. The markdown blockquote
  formatter normalizes line breaks (collapsing runs of blank lines) only at
  format time, never at capture time.

## Files

```
Sources/TheBrowser/Clipboard/
  CitedClip.swift                 — model + format enum
  CitedClipFormatter.swift        — pure format renderers (testable)
  CitedClipboardPolicy.swift      — blocklist + sensitive-host helpers
  CitedClipboardStore.swift       — SQLite log (libsqlite3)
  CitedClipboardBridge.swift      — WKScriptMessageHandler
  CitedClipboardScript.swift      — WKUserScript (JS hook)
  CitedClipboardController.swift  — orchestrator + smart-paste rewriter
  CitedClipboardSettings.swift    — Settings tab UI
  CitedClipboardPopover.swift     — ⌘⇧V popover UI
```

Tests:

```
Tests/TheBrowserTests/
  CitedClipFormatterTests.swift
  CitedClipboardStoreTests.swift
  CitedClipboardPolicyTests.swift
```
