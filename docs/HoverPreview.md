# Hover Preview — Design

Goal: while ⌘ is held over an `<a>` element in any tab, after 200ms show a
floating panel that previews the destination — favicon + title + URL up top, a
one-line AI summary as soon as it lands, the readable body preview below, and
quick actions (Open / Open as background / Pin) in the footer. Cheap to render,
cheap to dismiss, doesn't burn a tab.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│ WKWebView (the page)                                    │
│  ├─ linkHoverUserScript  ── post {kind,url,rect,…} ───┐ │
│                                                       │ │
│  LinkHoverBridge (WKScriptMessageHandler) ────────────┘ │
│  │                                                      │
│  ├──> HoverPreviewModel (@MainActor ObservableObject)   │
│  │     ├─ HoverPreviewCache (LRU, 50)                   │
│  │     ├─ HoverPreviewPrefetcher (sem 4, battery gate)  │
│  │     │     └─ HoverPreviewFetcher (URLSession only)   │
│  │     └─ HoverPreviewSummarizer (fast model)           │
│  │                                                      │
│  └──> HoverPreviewPanel (SwiftUI floating overlay)      │
└─────────────────────────────────────────────────────────┘
```

## 1. The hover bridge

`LinkHoverBridge` mirrors `TextSelectionBridge`: a single
`WKScriptMessageHandler` per tab, plus a `WKUserScript` (atDocumentEnd, all
frames, weakly held tab reference).

The injected JS:

- Tracks the link the pointer is over via `pointerover` / `pointerout`, walking
  to the nearest `<a[href]>` ancestor so spans-inside-links work.
- Tracks the modifier state via `keydown` / `keyup` on `meta` / `alt` / `shift`,
  and the current `e.metaKey` / `e.altKey` / `e.shiftKey` at pointer events.
- Emits three kinds of messages:
  - `peek` — modifier is currently down and the hover-delay timer (default
    200ms) fired. Posts `{kind, url, title, x, y, width, height,
    sameOrigin, isAnchorOnly}`.
  - `prefetch` — modifier is *not* down, hovering quietly for the prefetch
    delay (default 800ms). Sent once per (link, session) until cache eviction.
  - `leave` — pointer moved off the link and the modifier is no longer held.
- The viewport rect for `peek` is in CSS pixels relative to the visible
  viewport — same coordinate space `TextSelectionBridge` already uses, which the
  SwiftUI overlay sized to the WKWebView consumes directly.
- The user's chosen modifier (⌘/⌥/⇧) is read from Swift defaults and inlined
  into the user script at boot, so JS doesn't need to round-trip on key events.

The bridge filters `peek` events: same-origin anchor-only links (`#fragment`
where everything else matches the current page URL) are dropped at the JS layer
so the panel never appears for in-page jumps.

## 2. Off-screen extraction

`HoverPreviewFetcher.fetch(url:)` is a plain `URLSession` GET, not a hidden
WKWebView. Modeled after `NativeBrowserFetcher` in
[FetchTool.swift](Sources/TheBrowser/Chat/NativeBrowserTools/FetchTool.swift):

- 15 s timeout, Safari UA, `Accept: text/html,…`.
- Pulls `<title>`, `<meta name="description">`, `<meta property="og:description">`,
  `<link rel="icon">`, and a stripped-text body capped at ~24 KB (matches Smart
  Read's `extractReadablePage` budget).
- Maps status codes:
  - `401 / 403` → `.authRequired` (panel shows "preview unavailable, sign-in
    needed" + Open action).
  - Network failure / non-HTML → `.unavailable(reason)`.
  - 2xx with body but no readable text — typical of CORS-opaque SPAs — falls
    back to `(title, description)` only and the panel hides the body scroller.

This is the same readable-text shape Smart Read consumes (`ReadablePageExtraction`),
so the panel reuses Smart Read's body styling.

## 3. Cache + prefetch coordinator

`HoverPreviewCache` is an in-memory ordered dictionary keyed by absolute URL.
50-entry cap, LRU eviction, session-scoped. Entry stores `HoverPreviewContent`
(fetched body) and an optional `summary` so re-hovering the same link is
instant.

`HoverPreviewPrefetcher` is a `@MainActor` actor-style coordinator with a
4-slot semaphore. Before queueing a fetch it checks:

1. `BatteryMonitor.isOnBattery && ProcessInfo.processInfo.isLowPowerModeEnabled`
   → skip silently.
2. URL host matches the user's prefetch blocklist → skip silently.
3. Already in cache or in-flight → skip silently.

Prefetches use the same `HoverPreviewFetcher` as on-demand peeks. The peek path
short-circuits the prefetcher: if the entry is already cached, the panel goes
from "hover → ⌘" to "panel visible" in under a frame.

`BatteryMonitor` reads `IOPSCopyPowerSourcesInfo` once per query and observes
`NSProcessInfoPowerStateDidChangeNotification` for Low Power Mode toggles. The
result is cached so we don't poll IOKit on every hover.

## 4. View model

`HoverPreviewModel` (`@MainActor`, `ObservableObject`) keeps a single
`PeekSession`:

```swift
struct PeekSession {
    let id: UUID                  // stable across content swaps for transitions
    var url: URL
    var anchor: CGRect            // viewport CSS pixels
    var content: ContentState     // .loading | .ready(HoverPreviewContent) | .unavailable(reason)
    var summary: SummaryState     // .pending | .ready(String) | .failed
}
```

API:

- `peek(url:, anchor:, in tab:)` — if the URL differs from the current session,
  smoothly swap content (keep the panel mounted, just replace state); cancel
  prior summary task; reuse cached entry if present, otherwise kick a fetch.
- `prefetch(url:)` — forwards to the prefetcher.
- `dismiss()` — fades panel.
- `setPanelHover(_:)` and `setPointerStillOnLink(_:)` — drive the dismissal
  state machine. Panel only fades when **both** are false for the leave-grace
  window (160ms).

Summaries call `AIProviderClient.ask(prompt:, systemPromptOverride:,
modelOverride:)` with `provider.fastModelID`, exactly the way
`SmartReadClient.summarize` does — but with a one-sentence-only prompt that
trims to a single concrete sentence (no JSON, no bullets, no markdown). The
summary is cached on the cache entry, so the second peek doesn't re-call the
model.

## 5. Panel

`HoverPreviewPanel` is a SwiftUI view sized 480×360pt:

```
┌───────────────────────────────────────────────────────┐
│ [favicon]  Page title goes here                       │
│            https://example.com/path                   │  ← header
├───────────────────────────────────────────────────────┤
│ ✨ One-line summary — "GitHub issue about X, asks Y." │  ← AI line
├───────────────────────────────────────────────────────┤
│ Readable preview text begins here. Lorem ipsum…       │
│ More text. Scrollable.                               ↕│
├───────────────────────────────────────────────────────┤
│ Open  ⏎    Open in background  ⌘⏎    Pin              │  ← footer
└───────────────────────────────────────────────────────┘
```

Visuals match `SmartReadCard` (Palette.surface plate, 1px stroke, 12pt
corner). Same loading shimmer pattern. The summary is its own row so it can
flip from shimmer → text without re-laying out the panel.

Anchoring reuses the geometry math from `TextSelectionOverlay.summaryPosition`:
try right, then left, then below, then above the link rect, clamped to the
viewport.

Smooth swap: when the model's URL changes, the panel doesn't dismount — only
the content rows replace via `.transition(.opacity)`. The frame stays put so
the panel doesn't appear to jump.

## 6. Wiring

- `BrowserTab.init` registers the bridge and adds the user script. The script
  is rebuilt each `BrowserTab.init` from current settings (modifier, delays,
  enabled flag) so per-launch settings changes apply.
- `BrowserModel.openInNewTab(url:, background:, pinned:)` — single new API
  used by the panel's footer. `background` skips selection; `pinned` flags
  the tab as pinned (TabRailView sorts pinned tabs first — minimal pin
  semantics for v1).
- `BrowserShellView` instantiates `HoverPreviewModel`, layers
  `HoverPreviewPanel` in the same overlay stack as `TextSelectionOverlay`, and
  installs a local NSEvent monitor for `keyDown` so Return / ⌘+Return fire the
  panel actions while it's visible.
- Click-outside dismissal piggybacks on `NSEvent.addLocalMonitorForEvents` for
  `.leftMouseDown`: if the panel is visible and the click is outside the
  panel's frame, dismiss and let the event continue.

## 7. Settings

Under General → Browsing:

| Key | Default |
| --- | --- |
| `hoverPreview.enabled` | `true` |
| `hoverPreview.modifier` | `command` |
| `hoverPreview.hoverDelayMs` | `200` |
| `hoverPreview.prefetchDelayMs` | `800` |
| `hoverPreview.prefetchBlocklist` | `""` (newline-separated domain patterns) |

## 8. Edge cases (codified)

| Case | Behavior |
| --- | --- |
| `#fragment` same-page anchor | JS drops the peek event; nothing renders. |
| 401 / 403 | Fetcher reports `.authRequired`; panel shows "Preview unavailable — open to view" with Open enabled. |
| CORS-opaque / SPA shell | Fetcher returns `(title, description)` with empty body; panel hides the body scroller. |
| Hover swap | Model replaces content in place; panel id stays, animations are content-only. |
| Battery + Low Power | Prefetcher silently skips. Manual peek (⌘) still works — the user explicitly asked. |
| Blocklisted host | Prefetcher silently skips. Manual peek still fetches. |

## 9. What we explicitly are *not* building

- A second hidden `WKWebView` per preview (too expensive — uses RAM, runs JS,
  fetches images). The "Open as background tab" footer button is the only
  place we spin up a real WKWebView.
- Server-rendered link cards. No remote service is involved.
- Persistent cache. Session-only, cleared on app relaunch.
