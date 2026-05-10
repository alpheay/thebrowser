# TheBrowser

A native macOS web browser with a built-in AI side panel. Built in Swift 6 / SwiftUI on top of WebKit, with first-class hooks into the [Codex CLI](https://github.com/openai/codex) and the [Claude CLI](https://github.com/anthropics/claude-code) so the assistant can read the page you're on and drive native browser tools (open URLs, switch tabs, etc.) on your behalf.

> Status: pre-release. Expect rough edges, breaking changes, and missing platform features.

## Why

I built TheBrowser because I wasn't happy with any of the AI browsers out there, and I wanted to move off the mainstream ones too. The alternatives all felt either bloated, gimmicky, or built around somebody else's subscription.

So I made my own.

The idea is to stay minimal and clean, and to lean on tools you already use. There's no new subscription to sign up for — TheBrowser plugs straight into your existing Codex or Claude CLI and everything just works. You own your data, you own your config, and if a piece doesn't fit how you work, swap it out. The whole project is open source.

Honestly, I made it for me. I just figured enough other people would want the same thing that it was worth opening up.

## Install

Grab the latest `.dmg` from the [Releases page](https://github.com/alpheay/thebrowser/releases/latest), open it, and drag **TheBrowser** to **Applications**.

The DMG is a universal binary (Apple Silicon + Intel) and is ad-hoc signed but not yet notarised — so on first launch macOS will warn you about an "unidentified developer." Right-click the app and choose **Open** to bypass the prompt; you only need to do this once.

Prefer to build it yourself? See [Build and run](#build-and-run) below.

## Features

- **Native macOS app** — SwiftUI shell, WebKit rendering, hidden title bar, dark by default.
- **AI chat panel** (`⌘J`) — talk to Codex or Claude with the active tab as context. Models are pluggable per provider (GPT-5.x, Claude Opus / Sonnet / Haiku 4.x).
- **Inline AI answers** — question-shaped queries get a fast summary card above the search results, cached across reload and back-nav.
- **Tool chain visibility** — see exactly which native browser tools (and MCP tools, if configured) the assistant called to answer you. Toggleable in Settings.
- **Tab rail** (`⌘B`) — collapsible vertical tab strip with hover-peek.
- **Pluggable search engine** — pick your default in Settings.
- **Browser migration** — import bookmarks and history from Chrome and Firefox.
- **Google account** — optional Google OAuth sign-in stored in the macOS Keychain.
- **Configurable keybindings** — every shortcut listed below can be rebound from Settings → Keybindings.

### Default keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘J` | Toggle AI chat panel |
| `⌘B` | Toggle tab rail |
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⌘L` | Focus address bar |

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 16 or the Swift 6.0 toolchain (`swift --version` ≥ 6.0)
- For AI features: a working [Codex CLI](https://github.com/openai/codex) and/or [Claude CLI](https://github.com/anthropics/claude-code) on `PATH`. The exact binary path can be overridden in Settings → AI.

## Build and run

```bash
git clone https://github.com/alpheay/thebrowser.git
cd thebrowser
swift run TheBrowser
```

To open in Xcode instead:

```bash
open Package.swift
```

Tests:

```bash
swift test
```

## Configuration

All configuration lives in the in-app **Settings** window (`⌘,`):

- **General** — default search engine.
- **Account** — optional Google account sign-in. Provide your own OAuth client ID; tokens are stored in the macOS Keychain.
- **AI** — pick provider (Codex or Claude), model, system prompt, allowed/disallowed tools, MCP config path, and CLI binary location.
- **Keybindings** — rebind any of the shortcuts above.
- **Migration** — import bookmarks and history from Chrome or Firefox.

No telemetry, no remote config, no account required to use the browser itself.

## Releases

The repo follows a simple two-branch model:

- **`main`** — active development. The `Tests` workflow runs on every push.
- **`production`** — release branch. Every push triggers the [`Release` workflow](.github/workflows/release.yml), which:
  1. Builds a universal (`arm64` + `x86_64`) release binary with SwiftPM.
  2. Wraps it in a `TheBrowser.app` bundle with a generated `Info.plist`.
  3. Ad-hoc codesigns the bundle.
  4. Packages a drag-to-Applications DMG via `hdiutil`.
  5. Auto-generates release notes from `git log` since the previous tag.
  6. Publishes a new [GitHub Release](https://github.com/alpheay/thebrowser/releases) tagged `v<date>-<shortsha>` with the DMG (and its SHA-256) attached.

To cut a release, fast-forward `production` to the commit you want to ship and push it:

```bash
git checkout production
git merge --ff-only main
git push origin production
```

The workflow can also be run manually from the Actions tab (`workflow_dispatch`).

Switching to a fully signed and notarised build (so users no longer see the "unidentified developer" warning) is a matter of adding a few Apple developer secrets — see the comment block at the bottom of [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Repo layout

```
Sources/TheBrowser/
  TheBrowserApp.swift        # App entry point
  BrowserShellView.swift     # Top-level window layout (rail | web | chat)
  BrowserModel.swift         # Tab + navigation state
  BrowserWebView.swift       # WKWebView host
  AIChatPanel.swift          # Chat side panel
  AIProviderClient.swift     # Codex / Claude CLI bridge
  AIAnswerView.swift         # Inline AI answer card on search results
  NativeBrowserTools.swift   # Tools exposed to the assistant
  GoogleAuth/                # Google OAuth + Keychain
  Migration/                 # Chrome / Firefox import
Tests/TheBrowserTests/
```

## Contributing

PRs welcome. By contributing, you agree that your contributions are licensed under the AGPL-3.0 (see below) — there is no separate CLA.

Before opening a PR:

1. `swift build` cleanly with no new warnings.
2. `swift test` passes.
3. Conventional Commits-style commit messages (`feat:`, `fix:`, `refactor:`, …).

## License

TheBrowser is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. The full text is in [LICENSE](LICENSE).

In plain English, this means:

- **You can** use, copy, modify, and redistribute the software, including for commercial purposes.
- **You must** keep it open source. Any fork, modified version, or derivative work — whether distributed as a binary, shipped as a desktop app, or made available to users over a network — must also be released under AGPL-3.0, with complete corresponding source code available to its users.
- **You must** preserve the copyright and license notices, and (per AGPL-3.0 §5(d)) keep the "Appropriate Legal Notices" visible in any interactive UI of your derivative — i.e. your fork has to tell its users it's based on TheBrowser and where they can get the source.
- **You must not** add further restrictions, sub-license, or relicense the work under a more permissive license.

If you build something on top of TheBrowser, please also drop a note in the issue tracker so we can link to it from the README — not a license requirement, just appreciated.

Copyright © the TheBrowser contributors.
