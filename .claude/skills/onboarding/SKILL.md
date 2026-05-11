---
name: onboarding
description: Use this skill when the user asks to "onboard", get "oriented", "introduce me to the codebase", "show me around", "what is this project", or otherwise wants a fast tour of TheBrowser before starting work. Also use on a fresh checkout or first session in this repo when the user hasn't given a specific task yet.
version: 2.0.0
---

# TheBrowser — Onboarding

A native macOS browser written in Swift / SwiftUI with a built-in AI side panel that shells out to local `codex` or `claude` CLIs. The assistant can read the active tab and drive native browser tools (open URLs, switch tabs, fetch pages, etc.) on the user's behalf. This skill gives you a working mental model so you can jump straight into a task.

## What it is

- **Platform:** macOS 14+, Swift 6.0, single SwiftUI executable
- **Entry point:** [TheBrowserApp.swift](Sources/TheBrowser/App/TheBrowserApp.swift) → root view is `BrowserShellView`
- **Package:** SwiftPM, no external dependencies — see [Package.swift](Package.swift)
- **Window layout:** three columns inside one window — tab rail (left) · webview center · AI chat (right). Each side panel toggles with a spring animation.
- **Look & feel:** dark-mode-only by design. All colors/typography/motion live in [DesignSystem.swift](Sources/TheBrowser/DesignSystem/DesignSystem.swift) (`Palette`, `Typography`, `Motion`, `Metrics`).
- **Source layout:** files are grouped by feature under `Sources/TheBrowser/<Area>/`. The areas are listed below.

## Build & run

```sh
swift build              # debug build
swift run TheBrowser     # launch the app
swift test               # run the test suite (Swift Testing, not XCTest)
```

Tests use `import Testing` + `@Test` / `@Suite` macros. Don't reach for XCTest.

## Architecture map

Files are grouped by area under `Sources/TheBrowser/<Area>/`. You rarely need to touch more than one area for a single task.

### `App/` — entry point, defaults, shortcuts, window chrome
- [TheBrowserApp.swift](Sources/TheBrowser/App/TheBrowserApp.swift) — `@main` struct; hosts `BrowserShellView` and the settings window. Forces `.preferredColorScheme(.dark)`.
- [AppDefaults.swift](Sources/TheBrowser/App/AppDefaults.swift) — `PreferenceKey` constants and `UserDefaults.register(defaults:)`. **All persisted state goes through this enum** — don't sprinkle string keys around.
- [KeyboardShortcuts.swift](Sources/TheBrowser/App/KeyboardShortcuts.swift) / [KeyboardShortcutHost.swift](Sources/TheBrowser/App/KeyboardShortcutHost.swift) — capture and dispatch user-customizable shortcuts.
- [WindowChrome.swift](Sources/TheBrowser/App/WindowChrome.swift) — reroutes the green traffic-light button to native full-screen instead of macOS "maximize."

### `Browser/` — tabs, WKWebView, address bar, reader views
- [BrowserModel.swift](Sources/TheBrowser/Browser/BrowserModel.swift) — `@MainActor` `ObservableObject` owning the tab list, selection, address draft, panel visibility. The single source of truth views observe.
- [BrowserModels.swift](Sources/TheBrowser/Browser/BrowserModels.swift) — `BrowserTab` (wraps a `WKWebView` + KVO observations + dark-mode user script + YouTube cookie hack + text-selection bridge + smart-read state), `AddressResolver` (URL vs. search heuristic), `BrowserPageContext`.
- [BrowserWebView.swift](Sources/TheBrowser/Browser/BrowserWebView.swift) — `NSViewRepresentable` bridge for the tab's `WKWebView`.
- [BrowserPDFView.swift](Sources/TheBrowser/Browser/BrowserPDFView.swift) — `BrowserTabContent` switch between HTML and PDFKit rendering.
- [BrowserShellView.swift](Sources/TheBrowser/Browser/BrowserShellView.swift) — root layout, hover-peek rail behavior, keyboard shortcut wiring, first-run migration sheet, smart-read trigger, reader-mode overlay.
- [BrowserToolbar.swift](Sources/TheBrowser/Browser/BrowserToolbar.swift) — back/forward/reload, address field.
- [TabRailView.swift](Sources/TheBrowser/Browser/TabRailView.swift) — left rail (tabs, new-tab CTA).
- [HomePageView.swift](Sources/TheBrowser/Browser/HomePageView.swift) — new-tab page.
- [ReaderModeView.swift](Sources/TheBrowser/Browser/ReaderModeView.swift) — distraction-free reading overlay.
- [SmartReadView.swift](Sources/TheBrowser/Browser/SmartReadView.swift) — `SmartReadModel` + the TL;DR/key-points card. AI-driven page summary cached per-tab.
- [TextSelectionBridge.swift](Sources/TheBrowser/Browser/TextSelectionBridge.swift) / [TextSelectionWidget.swift](Sources/TheBrowser/Browser/TextSelectionWidget.swift) — JS hook that posts selection rects + the floating "ask the AI about this" widget that appears.
- [HoverPreview/](Sources/TheBrowser/Browser/HoverPreview/) — ⌘-hover preview panel for `<a>` links: cache, prefetcher (battery-gated), key monitor, JS bridge. Design notes in [docs/HoverPreview.md](docs/HoverPreview.md).

### `Chat/` — AI side panel, provider bridge, tools, artifacts
- [AIChatPanel.swift](Sources/TheBrowser/Chat/AIChatPanel.swift) — right-side panel UI and `ChatViewModel` (messages, draft, send loop, tool-call rendering). Assistant replies render as markdown via `MarkdownView`.
- [AIProviderClient.swift](Sources/TheBrowser/Chat/AIProviderClient.swift) — provider abstraction. Two providers: `.codex` and `.claude`. Builds CLI arguments in `CLIArguments`, spawns the process inside the session directory, parses stdout (Codex writes to a temp file; Claude streams JSON). Each provider has its own `AvailableModels` list and a built-in system prompt that **replaces** the CLI's default so user CLAUDE.md / codex config doesn't leak in.
- [ChatSessionStore.swift](Sources/TheBrowser/Chat/ChatSessionStore.swift) — persists each chat under `~/.thebrowser/sessions/<id>/messages.json`. The same directory is also the CLI's working directory, isolating sessions from the user's projects.
- [ModelPickerPopover.swift](Sources/TheBrowser/Chat/ModelPickerPopover.swift) — provider/model picker next to the send button.
- [SessionHistoryPopover.swift](Sources/TheBrowser/Chat/SessionHistoryPopover.swift) — prior-session browser.
- [ChatAttachmentChip.swift](Sources/TheBrowser/Chat/ChatAttachmentChip.swift) — page-context attachment UI.
- [NativeBrowserTools.swift](Sources/TheBrowser/Chat/NativeBrowserTools.swift) — tool definitions, parsing, executor. Tool names: `open`, `search`, `fetch`, `read_tabs`, `read_highlights`, `read_smart_read`, `create_artifact`, `web_control`. Each tool's implementation lives in [NativeBrowserTools/](Sources/TheBrowser/Chat/NativeBrowserTools/).
- [ArtifactStore.swift](Sources/TheBrowser/Chat/ArtifactStore.swift) / [ArtifactMark.swift](Sources/TheBrowser/Chat/ArtifactMark.swift) — AI-generated HTML written to `~/.thebrowser/web_artifacts/<timestamp>_<slug>.html`; each file is self-contained and openable in any browser.

### `Search/` — in-app SERP + inline AI answer card
- [SearchEngine.swift](Sources/TheBrowser/Search/SearchEngine.swift) — enum of supported engines (DuckDuckGo, Brave, Bing, Google) + URL builder.
- [SearchResultsClient.swift](Sources/TheBrowser/Search/SearchResultsClient.swift) / [SearchResultsView.swift](Sources/TheBrowser/Search/SearchResultsView.swift) — in-app rendered search results (no full webview round trip for the SERP).
- [QuestionDetector.swift](Sources/TheBrowser/Search/QuestionDetector.swift) — heuristic for "is this query question-shaped?" — gates whether to show the AI answer card.
- [AIAnswerClient.swift](Sources/TheBrowser/Search/AIAnswerClient.swift) / [AIAnswerCache.swift](Sources/TheBrowser/Search/AIAnswerCache.swift) / [AIAnswerView.swift](Sources/TheBrowser/Search/AIAnswerView.swift) — fast AI summary card above search results, with inline citation pills. Cache survives reload and back-nav.

### `Clipboard/` — cited copy/paste
- [CitedClipboardController.swift](Sources/TheBrowser/Clipboard/CitedClipboardController.swift) — singleton coordinator. Owns capture (JS copy event → `CitedClip` + pasteboard writes for plain/HTML/custom JSON UTI) and the smart-paste rewriter (rewrites plain-text rep when a known markdown app activates).
- [CitedClipboardScript.swift](Sources/TheBrowser/Clipboard/CitedClipboardScript.swift) — `WKUserScript` injected at document start.
- [CitedClipboardBridge.swift](Sources/TheBrowser/Clipboard/CitedClipboardBridge.swift) — per-tab `WKScriptMessageHandler`.
- [CitedClipboardPolicy.swift](Sources/TheBrowser/Clipboard/CitedClipboardPolicy.swift) — per-app rules (markdown / richText / plain).
- [CitedClipFormatter.swift](Sources/TheBrowser/Clipboard/CitedClipFormatter.swift) — citation footer formatting.
- [CitedClipboardStore.swift](Sources/TheBrowser/Clipboard/CitedClipboardStore.swift) / [CitedClipboardPopover.swift](Sources/TheBrowser/Clipboard/CitedClipboardPopover.swift) / [CitedClipboardCursorPanel.swift](Sources/TheBrowser/Clipboard/CitedClipboardCursorPanel.swift) — recent-clips browser and cursor-anchored popover.
- Design notes: [docs/cited-clipboard.md](docs/cited-clipboard.md).

### `DesignSystem/`
- [DesignSystem.swift](Sources/TheBrowser/DesignSystem/DesignSystem.swift) — `Palette`, `Typography`, `Motion`, `Metrics`.
- [MarkdownView.swift](Sources/TheBrowser/DesignSystem/MarkdownView.swift) — markdown renderer for assistant replies and AI answers.
- [BrandMarks.swift](Sources/TheBrowser/DesignSystem/BrandMarks.swift) — `OpenAIMark`, `ClaudeMark`, `DiscordMark`, `ProviderMark` shape views.

### `Settings/`
- [SettingsView.swift](Sources/TheBrowser/Settings/SettingsView.swift) — preferences window: General (search engine), Account (Google + Discord), AI (provider/model/system prompt/tools/MCP config/CLI paths), Keybindings, Migration.

### `Notifications/` — in-app toast center
- [AppNotification.swift](Sources/TheBrowser/Notifications/AppNotification.swift) — `AppNotificationKind` + `AppNotification` value type + `NotificationCorner` enum.
- [AppNotificationCenter.swift](Sources/TheBrowser/Notifications/AppNotificationCenter.swift) — `ObservableObject` queue.
- [NotificationOverlay.swift](Sources/TheBrowser/Notifications/NotificationOverlay.swift) / [NotificationToast.swift](Sources/TheBrowser/Notifications/NotificationToast.swift) — overlay window pinned to a configurable corner.

### `GoogleAuth/` — Google OAuth + Keychain
- [GoogleAuthService.swift](Sources/TheBrowser/GoogleAuth/GoogleAuthService.swift) — token exchange + refresh.
- [GoogleAccountStore.swift](Sources/TheBrowser/GoogleAuth/GoogleAccountStore.swift) — `ObservableObject` for the signed-in state.
- [GoogleAccountView.swift](Sources/TheBrowser/GoogleAuth/GoogleAccountView.swift) / [GoogleAuthWebSheet.swift](Sources/TheBrowser/GoogleAuth/GoogleAuthWebSheet.swift) — sign-in UI.
- [KeychainStore.swift](Sources/TheBrowser/GoogleAuth/KeychainStore.swift) — per-call service identifier with data-protection keychain (used by both Google and Discord stores).

### `Discord/` — Discord OAuth
- [DiscordAuthService.swift](Sources/TheBrowser/Discord/DiscordAuthService.swift) / [DiscordAccountStore.swift](Sources/TheBrowser/Discord/DiscordAccountStore.swift) / [DiscordAccountView.swift](Sources/TheBrowser/Discord/DiscordAccountView.swift) / [DiscordAuthWebSheet.swift](Sources/TheBrowser/Discord/DiscordAuthWebSheet.swift) — mirrors the Google auth shape.
- [DiscordTypes.swift](Sources/TheBrowser/Discord/DiscordTypes.swift) / [DiscordTheme.swift](Sources/TheBrowser/Discord/DiscordTheme.swift).

### `Migration/` — Chrome / Firefox import
- First-run sheet that imports bookmarks/history/cookies/passwords. [BrowserMigrationService.swift](Sources/TheBrowser/Migration/BrowserMigrationService.swift) is the entry point; [MigrationImportStore.swift](Sources/TheBrowser/Migration/MigrationImportStore.swift) is the persisted index.

## Conventions

- **Commit messages: Conventional Commits.** `feat:`, `fix:`, `refactor:`, `style:`, `test:`, `docs:`, `chore:`. Lowercase prefix, short subject. Look at `git log --oneline` for the house style.
- **Never add `Co-Authored-By: Claude` trailers.** This repo strips them.
- **Parallel agents may share this checkout.** Don't `git add -A` blindly, don't try to reconcile unexpected files or branches you didn't create — assume another agent is working in parallel. Only stage files you touched.
- **`@MainActor` everywhere UI state lives.** `BrowserModel`, `BrowserTab`, `ChatViewModel`, `ChatSessionStore`, `SmartReadModel`, `AppNotificationCenter`, `CitedClipboardController`, `*AccountStore` are all main-actor; respect it when adding new methods.
- **One `Palette` / one `Typography`.** Never inline hex colors or `Font.system(...)` literals in views — extend the design system file instead. Accent color is white only.
- **Dark mode is non-negotiable.** Views set `.preferredColorScheme(.dark)`. A `WKUserScript` forces dark color-scheme on every page; YouTube has its own cookie path.
- **No emojis in user-facing text** unless the user explicitly asks. The shipped system prompts for the AI assistant and AI answer card say so too.
- **All persisted prefs go through `PreferenceKey`.** Read via `@AppStorage(PreferenceKey.foo)` in views or `UserDefaults.standard` in models.

## Where state lives

- **`UserDefaults`** — provider, model, CLI paths, sandbox mode, shortcuts, migration flags, hover-preview tuning, notification corner, cited-clipboard rules. Always via `PreferenceKey`.
- **Keychain** — Google and Discord OAuth tokens (`KeychainStore`, data-protection class, per-call service ID).
- **`~/.thebrowser/sessions/<id>/messages.json`** — chat history per session. Also the CLI process's `cwd`.
- **`~/.thebrowser/web_artifacts/<stamp>_<slug>.html`** — AI-generated artifacts (`ArtifactStore`).
- **In-memory only** — open tabs, scroll position, hover-preview cache (LRU 50), webview cookies (`WKWebsiteDataStore.default()`).

## Common tasks — where to start

| Task | Start in |
|---|---|
| Add a setting | `App/AppDefaults.swift` (key + default) → `Settings/SettingsView.swift` (UI) |
| Add a keyboard shortcut | `App/AppDefaults.swift` (default binding) → `Browser/BrowserShellView.shortcutBindings` |
| New tab / navigation behavior | `Browser/BrowserModel.swift` or `Browser/BrowserModels.swift` (`BrowserTab`) |
| Change chat UI | `Chat/AIChatPanel.swift` |
| Change how the AI is called | `Chat/AIProviderClient.swift` + `CLIArguments` |
| Add an AI provider or model | `AIProviderKind` enum and `availableModels` in `Chat/AIProviderClient.swift` |
| Add a native browser tool | `Chat/NativeBrowserTools.swift` (enum + executor) → new file under `Chat/NativeBrowserTools/` |
| Add a tab-rail / toolbar control | `Browser/TabRailView.swift` / `Browser/BrowserToolbar.swift` |
| Browser data import | `Migration/` |
| Inline AI answers on SERPs | `Search/AIAnswerView.swift` + `AIAnswerClient`/`AIAnswerCache` |
| Hover-preview behavior | `Browser/HoverPreview/` (see [docs/HoverPreview.md](docs/HoverPreview.md)) |
| Smart Read card / shortcut | `Browser/SmartReadView.swift` + `BrowserShellView.triggerSmartRead` |
| Cited-clipboard rules | `Clipboard/CitedClipboardController.swift` (see [docs/cited-clipboard.md](docs/cited-clipboard.md)) |
| In-app notifications | `Notifications/` |
| Google / Discord OAuth | `GoogleAuth/` or `Discord/` |

## Tests

[Tests/TheBrowserTests/](Tests/TheBrowserTests/) — Swift Testing. Coverage is concentrated on pure logic:

- **AI harness:** `CodexArgumentsTests`, `ClaudeArgumentsTests`, `ClaudeResponseParsingTests`, `PromptFormattingTests`, `ConfigurationLoadingTests`, `EffectiveSystemPromptTests`.
- **Sessions & shortcuts:** `ChatSessionStoreTests`, `AppShortcutTests`.
- **Browser model:** `BrowserModelTests`.
- **Native tools:** `NativeBrowserToolsTests`.
- **Search:** `QuestionDetectorTests`.
- **Hover preview:** `HoverPreviewExtractorTests`.
- **Cited clipboard:** `CitedClipFormatterTests`, `CitedClipboardPolicyTests`, `CitedClipboardStoreTests`.
- **Auth:** `GoogleAuthTests`.

UI / webview code is not unit-tested. `TestSupport.swift` has a `makeConfiguration` helper — use it instead of hand-constructing `AIHarnessConfiguration` in new tests.

## Quick gotchas

- The `codex` CLI is invoked with `--ignore-user-config`, `--ignore-rules`, and `--skip-git-repo-check` so behavior stays deterministic. Don't remove those without thinking.
- The `claude` CLI is invoked with `--no-session-persistence` and `--print --output-format json`; the JSON `.result` field is what's shown. Default model + system prompt are explicitly overridden — see `effectiveSystemPrompt` in `CLIArguments`.
- `BrowserTab.navigate(to:)` distinguishes URL vs. search via `AddressResolver`; "looks like a domain" means contains a dot and no whitespace.
- `WKWebView` observations are `@preconcurrency` and bounce back to `@MainActor` via `Task { @MainActor in ... }` — keep that pattern.
- `WKWebView` user content controllers fan out: dark-mode CSS, YouTube cookie hack, hover-link bridge, text-selection bridge, cited-clipboard script. When adding a new injected script, register/unregister cleanly in `BrowserTab` setup/teardown so hibernation works.
- The smart-read shortcut respects hibernation: see `BrowserTab.isSmartReadEligible`. There was a real race here (see commit `b560b09`) — don't undo the guard.

## Release process

Two-branch model:
- **`main`** — active development. `Tests` workflow runs on every push ([.github/workflows/tests.yml](.github/workflows/tests.yml)).
- **`production`** — push to ship. [.github/workflows/release.yml](.github/workflows/release.yml) builds a universal DMG, ad-hoc signs it, generates release notes from `git log`, and publishes a GitHub Release tagged `v<date>-<shortsha>`.

To cut a release, fast-forward `production` to the commit on `main` and push.

## Use this skill to

- Answer "what is this project?" without re-reading every file.
- Pick the right starting file for a task by area.
- Avoid re-deriving conventions that are already established (commits, palette, main-actor, parallel agents, dark-mode-only, no emojis).
