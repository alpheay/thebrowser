---
name: onboarding
description: Use this skill when the user asks to "onboard", get "oriented", "introduce me to the codebase", "show me around", "what is this project", or otherwise wants a fast tour of TheBrowser before starting work. Also use on a fresh checkout or first session in this repo when the user hasn't given a specific task yet.
version: 1.0.0
---

# TheBrowser — Onboarding

A native macOS browser written in Swift / SwiftUI with a built-in AI chat panel that shells out to local `codex` or `claude` CLIs. This skill gives a working mental model of the codebase so you can jump straight into a task.

## What it is

- **Platform:** macOS 14+, Swift 6.0, single SwiftUI executable
- **Entry point:** [TheBrowserApp.swift](Sources/TheBrowser/TheBrowserApp.swift) → root view is `BrowserShellView`
- **Package:** SwiftPM, no external dependencies — see [Package.swift](Package.swift)
- **Window layout:** three columns inside one window — tab rail (left) · webview center · AI chat (right). Each side panel can be toggled and animates with a spring.
- **Look & feel:** dark-mode-only by design. All colors/typography/motion live in [DesignSystem.swift](Sources/TheBrowser/DesignSystem.swift) (`Palette`, `Typography`, `Motion`, `Metrics`).

## Build & run

```sh
swift build              # debug build
swift run TheBrowser     # launch the app
swift test               # run the test suite (Swift Testing, not XCTest)
```

Tests use `import Testing` + `@Test` / `@Suite` macros. Don't reach for XCTest.

## Architecture map

Group files by area; you rarely need to touch more than one area for a single task.

### Browser core
- [BrowserModel.swift](Sources/TheBrowser/BrowserModel.swift) — `@MainActor` `ObservableObject` owning the tab list, selection, address draft, panel visibility flags. The single source of truth the views observe.
- [BrowserModels.swift](Sources/TheBrowser/BrowserModels.swift) — `BrowserTab` (wraps a `WKWebView` + KVO observations + dark-mode user script + YouTube cookie hack), `AddressResolver` (URL vs. search heuristic), `BrowserPageContext`.
- [BrowserWebView.swift](Sources/TheBrowser/BrowserWebView.swift) — `NSViewRepresentable` bridge for the tab's `WKWebView`.
- [BrowserShellView.swift](Sources/TheBrowser/BrowserShellView.swift) — root layout, hover-peek rail behavior, keyboard shortcut wiring, first-run migration sheet.
- [BrowserToolbar.swift](Sources/TheBrowser/BrowserToolbar.swift) — back/forward/reload, address field.
- [TabRailView.swift](Sources/TheBrowser/TabRailView.swift) — left rail (tabs, new-tab CTA).
- [HomePageView.swift](Sources/TheBrowser/HomePageView.swift) — new-tab page.

### Search
- [SearchEngine.swift](Sources/TheBrowser/SearchEngine.swift) — enum of supported engines + URL builder.
- [SearchResultsClient.swift](Sources/TheBrowser/SearchResultsClient.swift) / [SearchResultsView.swift](Sources/TheBrowser/SearchResultsView.swift) — in-app rendered search results (no full webview round trip for the SERP).

### AI chat
- [AIChatPanel.swift](Sources/TheBrowser/AIChatPanel.swift) — right-side panel UI and `ChatViewModel` (messages, draft, send loop). Renders assistant replies as markdown via `MarkdownView`.
- [AIProviderClient.swift](Sources/TheBrowser/AIProviderClient.swift) — provider abstraction. Two providers: `.codex` and `.claude`. Builds CLI arguments in `CLIArguments`, spawns the process inside the session directory, parses stdout (Codex writes to a temp file; Claude streams JSON). Each provider has its own `AvailableModels` list and a built-in system prompt that **replaces** the CLI's default so user CLAUDE.md / codex config doesn't leak into responses.
- [ChatSessionStore.swift](Sources/TheBrowser/ChatSessionStore.swift) — persists each chat under `~/.thebrowser/sessions/<id>/messages.json`. The same directory is also the CLI's working directory, so each session is isolated from the user's projects.
- [ModelPickerPopover.swift](Sources/TheBrowser/ModelPickerPopover.swift) — provider/model picker next to the send button.
- [MarkdownView.swift](Sources/TheBrowser/MarkdownView.swift) — assistant-message renderer.

### Settings & preferences
- [AppDefaults.swift](Sources/TheBrowser/AppDefaults.swift) — `PreferenceKey` constants and `UserDefaults.register(defaults:)`. **All persisted state goes through this enum** — don't sprinkle string keys around.
- [SettingsView.swift](Sources/TheBrowser/SettingsView.swift) — preferences window (AI provider, model, paths, shortcuts).
- [KeyboardShortcuts.swift](Sources/TheBrowser/KeyboardShortcuts.swift) / [KeyboardShortcutHost.swift](Sources/TheBrowser/KeyboardShortcutHost.swift) — capture and dispatch user-customizable shortcuts.

### Migration (Chrome / Firefox import)
- [Sources/TheBrowser/Migration/](Sources/TheBrowser/Migration/) — first-run sheet that imports bookmarks/history/cookies/passwords from Chrome or Firefox. `BrowserMigrationService` is the entry point; `MigrationDestination` writes into TheBrowser's local stores; `MigrationImportStore` is the persisted index.

## Conventions

- **Commit messages: Conventional Commits.** `feat:`, `fix:`, `refactor:`, `style:`, `test:`, `docs:`, `chore:`. Lowercase prefix, short subject. Look at `git log --oneline` for the house style.
- **Never add `Co-Authored-By: Claude` trailers.** This repo strips them.
- **Parallel agents may share this checkout.** Don't `git add -A` blindly, don't try to reconcile unexpected files or branches you didn't create — assume another agent is working in parallel. Only stage files you touched.
- **`@MainActor` everywhere UI state lives.** `BrowserModel`, `BrowserTab`, `ChatViewModel`, `ChatSessionStore` are all main-actor; respect it when adding new methods.
- **One `Palette` / one `Typography`.** Never inline hex colors or `Font.system(...)` literals in views — extend the design system file instead. Accent color is white only.
- **Dark mode is non-negotiable.** Views set `.preferredColorScheme(.dark)`. There's a `WKUserScript` that forces dark color-scheme on every page; YouTube has its own cookie path.
- **No emojis in user-facing text** unless the user explicitly asks. The shipped system prompt for the AI assistant says so too.

## Where state lives

- **`UserDefaults`** — provider, model, CLI paths, sandbox mode, shortcuts, migration flags. Read via `@AppStorage(PreferenceKey.foo)` in views or `UserDefaults.standard` in models.
- **`~/.thebrowser/sessions/<id>/messages.json`** — chat history per session. Also serves as the CLI process's `cwd`.
- **In-memory only** — open tabs, scroll position, webview cookies (handled by `WKWebsiteDataStore.default()`).

## Common tasks — where to start

| Task | Start in |
|---|---|
| Add a setting | `AppDefaults.swift` (key + default) → `SettingsView.swift` (UI) |
| Add a keyboard shortcut | `AppDefaults.swift` (default binding) → `BrowserShellView.shortcutBindings` |
| New tab / navigation behavior | `BrowserTab` or `BrowserModel` |
| Change chat UI | `AIChatPanel.swift` |
| Change how the AI is called | `AIProviderClient.swift` + `CLIArguments` |
| Add an AI provider or model | `AIProviderKind` enum and `availableModels` |
| Add a tab-rail / toolbar control | `TabRailView` / `BrowserToolbar` |
| Browser data import | `Sources/TheBrowser/Migration/` |

## Tests

[Tests/TheBrowserTests/](Tests/TheBrowserTests/) — focused on the AI provider harness (`CLIArguments` builders for codex/claude), prompt formatting, response parsing, configuration loading, system-prompt composition, and `ChatSessionStore` persistence. UI/webview code is not unit-tested. `TestSupport.swift` has a `makeConfiguration` helper — use it instead of hand-constructing `AIHarnessConfiguration` in new tests.

## Quick gotchas

- The `codex` CLI is invoked with `--ignore-user-config --ignore-rules` and `--skip-git-repo-check` so behavior stays deterministic. Don't remove those without thinking.
- The `claude` CLI is invoked with `--no-session-persistence` and `--print --output-format json`; the JSON `.result` field is what's shown. Default model + system prompt are explicitly overridden — see `effectiveSystemPrompt` in `CLIArguments`.
- `BrowserTab.navigate(to:)` distinguishes URL vs. search via `AddressResolver`; "looks like a domain" means contains a dot and no whitespace.
- `WKWebView` observations are `@preconcurrency` and bounce back to `@MainActor` via `Task { @MainActor in ... }` — keep that pattern.

## Use this skill to

- Answer "what is this project?" without re-reading every file.
- Pick the right starting file for a task.
- Avoid re-deriving conventions that are already established (commits, palette, main-actor, parallel agents).
