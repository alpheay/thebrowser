# TheBrowser — Systems & Interaction Map

A color-coded map of the subsystems inside TheBrowser and how they talk to each
other. TheBrowser is a **single-process native macOS app** (Swift 6 · SwiftUI ·
WebKit, built with SwiftPM). The only child process is the AI provider CLI
(Claude or Codex); everything else runs on the main actor with reactive SwiftUI
state.

> The diagrams below are [Mermaid](https://mermaid.js.org/) — they render
> automatically on GitHub and in most Markdown viewers. Each subsystem is tinted
> by **layer**; the key is the color chart in the next section.

---

## Color chart (the key)

| Swatch | Layer | What lives here | Hex (fill / stroke) |
|:------:|-------|-----------------|---------------------|
| ⬜ | **App Shell & Window** | `@main` entry, layout orchestrator, keyboard, settings | `#E2E8F0` / `#475569` |
| 🟦 | **Browser Core** | tab model, navigation, toolbar, tab rail, home page | `#DBEAFE` / `#2563EB` |
| 🟩 | **Web Content & JS Bridges** | `WKWebView` + scripts injected into every page | `#CCFBF1` / `#0D9488` |
| 🟨 | **Reading & Capture** | reader mode, smart read, hover preview, find, cited clipboard | `#FEF9C3` / `#CA8A04` |
| 🟪 | **AI Assistant & Agent** | chat UI, agent harness, provider client, tools, sessions | `#EDE9FE` / `#7C3AED` |
| 🟧 | **Search** | engines, results rendering, fast inline AI answer | `#FFEDD5` / `#EA580C` |
| 🟫 | **Persistence** | SQLite stores, chat sessions, Keychain, UserDefaults | `#EFE4D3` / `#92400E` |
| 🟥 | **External & Integrations** | provider CLIs, Gmail/Google/Discord, the live web | `#FEE2E2` / `#DC2626` |

---

## 1 · System map

How the major pieces are wired. Solid arrows = ownership / direct calls;
dotted arrows = asynchronous data flow (streamed events, captured context).

```mermaid
flowchart TB
    User(["👤 User"])

    subgraph SHELL["⬜ App Shell &amp; Window"]
        App["TheBrowserApp<br/>@main entry"]
        Shell["BrowserShellView<br/>layout orchestrator"]
        Keys["KeyboardShortcuts<br/>⌘-bindings"]
        Settings["SettingsView (⌘,)"]
    end

    subgraph CORE["🟦 Browser Core"]
        Model["BrowserModel<br/>tabs · nav · hibernation"]
        Tab["BrowserTab × N"]
        Toolbar["BrowserToolbar<br/>URL bar · back/fwd"]
        Rail["TabRailView"]
        Home["HomePageView"]
    end

    subgraph WEB["🟩 Web Content &amp; JS Bridges"]
        WK["WKWebView (WebKit)"]
        SelBridge["TextSelectionBridge"]
        ClipBridge["CitedClipboardBridge"]
        HoverBridge["LinkHoverBridge"]
    end

    subgraph FEAT["🟨 Reading &amp; Capture"]
        Reader["ReaderModeView"]
        Smart["SmartReadView"]
        Hover["HoverPreview"]
        Find["FindBar (⌘F)"]
        ClipCtl["CitedClipboardController"]
        SelWidget["TextSelectionWidget"]
    end

    subgraph AI["🟪 AI Assistant &amp; Agent"]
        Chat["AIChatPanel<br/>chat UI + state"]
        Harness["AgentHarness<br/>invoke · stream · loop (≤25)"]
        Provider["AIProviderClient<br/>prompt builder"]
        Parser["NativeBrowserTools<br/>parse + execute"]
        Tools["Tools: open · search · fetch<br/>read_tabs · web_control<br/>mail_* · create_artifact"]
        Sessions["ChatSessionStore"]
        Artifacts["ArtifactStore"]
    end

    subgraph SEARCH["🟧 Search"]
        Engine["SearchEngine"]
        Results["SearchResultsView"]
        Answer["AIAnswerClient<br/>fast inline answer"]
    end

    subgraph STORE["🟫 Persistence"]
        History["HistoryStore<br/>~/.thebrowser/history.sqlite"]
        ClipStore["CitedClipboardStore<br/>SQLite"]
        Keychain["macOS Keychain"]
        Defaults["UserDefaults"]
    end

    subgraph EXT["🟥 External &amp; Integrations"]
        ClaudeCLI["Claude CLI<br/>stream-json"]
        CodexCLI["Codex CLI"]
        Gmail["Gmail OAuth + API v1"]
        GoogleD["Google / Discord OAuth"]
        Net["🌐 Live Web"]
    end

    %% Shell wiring
    User --> Shell
    User --> Keys
    App --> Shell
    Keys --> Shell
    Shell --> Model
    Shell --> Chat
    Shell --> Toolbar
    Shell --> Rail
    Settings --> Keychain
    Settings --> Defaults

    %% Browser core
    Model --> Tab
    Tab --> WK
    Toolbar --> Model
    Rail --> Model
    Model --> Home
    Model --> History

    %% Web bridges (injected into every page)
    WK --> SelBridge
    WK --> ClipBridge
    WK --> HoverBridge
    SelBridge --> SelWidget
    ClipBridge --> ClipCtl
    HoverBridge --> Hover
    ClipCtl --> ClipStore

    %% Reading features
    Tab --> Reader
    Tab --> Smart
    Find --> WK
    WK --> Net

    %% AI agent loop
    Chat --> Harness
    Harness --> Provider
    Provider --> ClaudeCLI
    Provider --> CodexCLI
    ClaudeCLI -.->|stream| Harness
    CodexCLI -.->|result| Harness
    Harness --> Parser
    Parser --> Tools
    Tools --> Model
    Tools --> Gmail
    Tools --> Artifacts
    Tools --> Net
    Chat --> Sessions
    SelWidget -.->|highlights| Chat
    ClipCtl -.->|cited clips| Chat
    Smart -.->|summary| Tools

    %% Search
    Toolbar --> Engine
    Engine --> Results
    Engine --> Answer
    Answer --> ClaudeCLI
    Results --> Net

    %% Integrations
    Gmail --> Keychain
    GoogleD --> Keychain

    %% ---- color classes ----
    classDef shell  fill:#E2E8F0,stroke:#475569,color:#0F172A;
    classDef core   fill:#DBEAFE,stroke:#2563EB,color:#0F172A;
    classDef web    fill:#CCFBF1,stroke:#0D9488,color:#0F172A;
    classDef feat   fill:#FEF9C3,stroke:#CA8A04,color:#0F172A;
    classDef ai     fill:#EDE9FE,stroke:#7C3AED,color:#0F172A;
    classDef search fill:#FFEDD5,stroke:#EA580C,color:#0F172A;
    classDef store  fill:#EFE4D3,stroke:#92400E,color:#0F172A;
    classDef ext    fill:#FEE2E2,stroke:#DC2626,color:#0F172A;

    class App,Shell,Keys,Settings shell;
    class Model,Tab,Toolbar,Rail,Home core;
    class WK,SelBridge,ClipBridge,HoverBridge web;
    class Reader,Smart,Hover,Find,ClipCtl,SelWidget feat;
    class Chat,Harness,Provider,Parser,Tools,Sessions,Artifacts ai;
    class Engine,Results,Answer search;
    class History,ClipStore,Keychain,Defaults store;
    class ClaudeCLI,CodexCLI,Gmail,GoogleD,Net ext;
```

---

## 2 · The AI agent loop

What happens between hitting **Send** and seeing an answer. The harness keeps
feeding tool results back to the provider until the model stops calling tools or
the iteration cap (`maxAgentIterations = 25`) is reached.

```mermaid
flowchart LR
    A["User sends<br/>message"] --> B["AIChatPanel"]
    B --> C["AIProviderClient<br/>build prompt:<br/>system · history · page<br/>context · tabs · highlights"]
    C --> D["AgentHarness<br/>spawn CLI subprocess"]
    D --> E{"Provider?"}
    E -->|Claude| F["stream-json<br/>token deltas"]
    E -->|Codex| G["single result"]
    F --> H["NativeBrowserTools<br/>detect tool-call JSON"]
    G --> H
    H --> I{"Tool call?"}
    I -->|yes| J["Execute tool<br/>open · fetch · read_tabs<br/>web_control · mail · artifact"]
    J --> K["Feed result back"]
    K --> D
    I -->|no| L["Final text →<br/>render + persist session"]

    classDef ai    fill:#EDE9FE,stroke:#7C3AED,color:#0F172A;
    classDef ext   fill:#FEE2E2,stroke:#DC2626,color:#0F172A;
    classDef store fill:#EFE4D3,stroke:#92400E,color:#0F172A;
    class A,B,C,D,H ai;
    class E,F,G ext;
    class I,J,K ai;
    class L store;
```

---

## 3 · Cited-clipboard capture

Every copy off a web page is tagged with its source so it can be pasted back
into chat (or anywhere) as a properly attributed Markdown citation.

```mermaid
flowchart LR
    S["Select text<br/>on a page"] --> Bridge["CitedClipboardBridge<br/>(injected JS)"]
    Bridge --> Meta["Capture<br/>title · URL · text"]
    Copy["⌘C"] --> Ctl["CitedClipboardController"]
    Meta --> Ctl
    Ctl --> Store["CitedClipboardStore<br/>SQLite log"]
    Ctl --> Fmt["CitedClipboardFormatter<br/>Markdown + citation"]
    Fmt --> Paste["⌘⇧V → chat highlight"]
    Paste --> Chat["AIChatPanel<br/>attachment chip"]

    classDef web   fill:#CCFBF1,stroke:#0D9488,color:#0F172A;
    classDef feat  fill:#FEF9C3,stroke:#CA8A04,color:#0F172A;
    classDef store fill:#EFE4D3,stroke:#92400E,color:#0F172A;
    classDef ai    fill:#EDE9FE,stroke:#7C3AED,color:#0F172A;
    class S,Bridge web;
    class Meta,Copy,Ctl,Fmt,Paste feat;
    class Store store;
    class Chat ai;
```

---

## Subsystem reference

| 🎨 | Subsystem | Key files | Responsibility |
|:--:|-----------|-----------|----------------|
| ⬜ | App Shell | [TheBrowserApp.swift](Sources/TheBrowser/App/TheBrowserApp.swift), [BrowserShellView.swift](Sources/TheBrowser/Browser/BrowserShellView.swift), [KeyboardShortcuts.swift](Sources/TheBrowser/App/KeyboardShortcuts.swift) | Entry point, master `rail │ center │ chat` layout, global ⌘-bindings |
| 🟦 | Browser Core | [BrowserModel.swift](Sources/TheBrowser/Browser/BrowserModel.swift), [BrowserModels.swift](Sources/TheBrowser/Browser/BrowserModels.swift), [BrowserToolbar.swift](Sources/TheBrowser/Browser/BrowserToolbar.swift), [TabRailView.swift](Sources/TheBrowser/Browser/TabRailView.swift) | Tab/navigation state, per-tab `WKWebView` lifecycle, idle-tab hibernation |
| 🟩 | Web & Bridges | [BrowserWebView.swift](Sources/TheBrowser/Browser/BrowserWebView.swift), [TextSelectionBridge.swift](Sources/TheBrowser/Browser/TextSelectionBridge.swift), [CitedClipboardBridge.swift](Sources/TheBrowser/Clipboard/CitedClipboardBridge.swift) | WebKit host + `postMessage` bridges for selection, copy, link-hover |
| 🟨 | Reading & Capture | [SmartReadView.swift](Sources/TheBrowser/Browser/SmartReadView.swift), [ReaderModeView.swift](Sources/TheBrowser/Browser/ReaderModeView.swift), [CitedClipboardController.swift](Sources/TheBrowser/Clipboard/CitedClipboardController.swift), [HoverPreview/](Sources/TheBrowser/Browser/HoverPreview), [FindBar/](Sources/TheBrowser/Browser/FindBar) | AI summaries, distraction-free reading, citations, link previews, ⌘F |
| 🟪 | AI Assistant | [AIChatPanel.swift](Sources/TheBrowser/Chat/AIChatPanel.swift), [AgentHarness.swift](Sources/TheBrowser/Chat/AgentHarness.swift), [AIProviderClient.swift](Sources/TheBrowser/Chat/AIProviderClient.swift), [NativeBrowserTools/](Sources/TheBrowser/Chat/NativeBrowserTools) | Chat state, CLI invoke + stream parse, tool-call loop, model picker |
| 🟧 | Search | [SearchEngine.swift](Sources/TheBrowser/Search/SearchEngine.swift), [SearchResultsView.swift](Sources/TheBrowser/Search/SearchResultsView.swift), [AIAnswerClient.swift](Sources/TheBrowser/Search/AIAnswerClient.swift) | Pluggable engines, results rendering, fast inline AI answer card |
| 🟫 | Persistence | [HistoryStore.swift](Sources/TheBrowser/History/HistoryStore.swift), [CitedClipboardStore.swift](Sources/TheBrowser/Clipboard/CitedClipboardStore.swift), [ChatSessionStore.swift](Sources/TheBrowser/Chat/ChatSessionStore.swift), [ArtifactStore.swift](Sources/TheBrowser/Chat/ArtifactStore.swift) | SQLite history/clips, JSON chat sessions, HTML artifacts |
| 🟥 | Integrations | [GmailStore.swift](Sources/TheBrowser/Integrations/Gmail/GmailStore.swift), [GmailOAuthService.swift](Sources/TheBrowser/Integrations/Gmail/GmailOAuthService.swift), [GoogleAuth/](Sources/TheBrowser/GoogleAuth), [Discord/](Sources/TheBrowser/Discord) | OAuth flows + token storage, Gmail API, exposed to AI as `mail_*` tools |

### Storage at a glance

| Store | Location | Tech |
|-------|----------|------|
| Browsing history | `~/.thebrowser/history.sqlite` | SQLite (system libsqlite3) |
| Cited clipboard log | `~/.thebrowser/` SQLite | SQLite |
| Chat sessions | `~/.thebrowser/sessions/` | JSON |
| Generated artifacts | `~/.thebrowser/artifacts/` | HTML files |
| OAuth tokens | macOS Keychain | Secure storage |
| Preferences | `com.venehealth.thebrowser` plist | UserDefaults |

---

*Generated from a source walk of `Sources/TheBrowser/`. Diagrams use Mermaid;
colors follow the chart in the [key](#color-chart-the-key) above.*
