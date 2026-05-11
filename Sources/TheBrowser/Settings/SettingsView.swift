import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @AppStorage(PreferenceKey.aiSystemPrompt) private var aiSystemPrompt = AppDefaults.defaultAISystemPrompt
    @AppStorage(PreferenceKey.aiTools) private var aiTools = ""
    @AppStorage(PreferenceKey.aiAllowedTools) private var aiAllowedTools = ""
    @AppStorage(PreferenceKey.aiDisallowedTools) private var aiDisallowedTools = ""
    @AppStorage(PreferenceKey.aiMCPConfigPath) private var aiMCPConfigPath = ""
    @AppStorage(PreferenceKey.aiExtraArguments) private var aiExtraArguments = ""
    @AppStorage(PreferenceKey.aiShowToolChain) private var aiShowToolChain = true
    @AppStorage(PreferenceKey.codexCLIPath) private var codexCLIPath = AppDefaults.defaultCodexCLIPath()
    @AppStorage(PreferenceKey.codexSandbox) private var codexSandbox = "read-only"
    @AppStorage(PreferenceKey.claudeCLIPath) private var claudeCLIPath = AppDefaults.defaultClaudeCLIPath()
    @AppStorage(PreferenceKey.searchEngine) private var searchEngine = SearchEngine.defaultValue.rawValue
    @AppStorage(PreferenceKey.notificationCorner) private var notificationCorner = NotificationCorner.topRight.rawValue
    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"
    @AppStorage(PreferenceKey.newTabShortcut) private var newTabShortcut = "command+t"
    @AppStorage(PreferenceKey.closeTabShortcut) private var closeTabShortcut = "command+w"
    @AppStorage(PreferenceKey.focusAddressShortcut) private var focusAddressShortcut = "command+l"
    @AppStorage(PreferenceKey.smartReadShortcut) private var smartReadShortcut = "shift+command+r"
    @AppStorage(PreferenceKey.readerModeShortcut) private var readerModeShortcut = "command+r"
    @AppStorage(PreferenceKey.pasteWithCitationShortcut) private var pasteWithCitationShortcut = "shift+command+v"
    @AppStorage(PreferenceKey.hoverPreviewEnabled) private var hoverPreviewEnabled = true
    @AppStorage(PreferenceKey.hoverPreviewModifier) private var hoverPreviewModifier = HoverPreviewModifier.command.rawValue
    @AppStorage(PreferenceKey.hoverPreviewDelayMs) private var hoverPreviewDelayMs = 200
    @AppStorage(PreferenceKey.hoverPreviewPrefetchDelayMs) private var hoverPreviewPrefetchDelayMs = 800
    @AppStorage(PreferenceKey.hoverPreviewPrefetchBlocklist) private var hoverPreviewBlocklist = ""
    @AppStorage(PreferenceKey.toolbarShowBack) private var toolbarShowBack = true
    @AppStorage(PreferenceKey.toolbarShowForward) private var toolbarShowForward = true
    @AppStorage(PreferenceKey.toolbarShowReload) private var toolbarShowReload = true
    @AppStorage(PreferenceKey.toolbarShowReaderMode) private var toolbarShowReaderMode = false
    @AppStorage(PreferenceKey.toolbarShowSmartRead) private var toolbarShowSmartRead = false
    @AppStorage(PreferenceKey.toolbarShowClipboard) private var toolbarShowClipboard = false
    @AppStorage(PreferenceKey.toolbarShowTabRailToggle) private var toolbarShowTabRailToggle = true
    @AppStorage(PreferenceKey.toolbarShowChatToggle) private var toolbarShowChatToggle = true

    @State private var selectedTab: SettingsTab = .general
    @State private var showClearAllConfirm = false
    @StateObject private var googleAccountStore = GoogleAccountStore.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(Palette.bgSunken)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Palette.stroke)
                        .frame(width: 1)
                }

            ScrollView {
                contentForTab
                    .padding(.horizontal, 40)
                    .padding(.vertical, 36)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("Tune your browser")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 24)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarRow(
                        tab: tab,
                        selected: tab == selectedTab,
                        action: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .general:
            generalSettings
        case .account:
            accountSettings
        case .toolbar:
            toolbarSettings
        case .ai:
            aiSettings
        case .clipboard:
            CitedClipboardSettingsContent()
        case .keybindings:
            keybindingsSettings
        case .migration:
            migrationSettings
        }
    }

    // MARK: - Account

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "Account", subtitle: "Sign in with Google to personalize The Browser.")
            GoogleAccountView(store: googleAccountStore)
        }
    }

    // MARK: - Toolbar

    private var toolbarSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "Toolbar", subtitle: "Choose which buttons appear in the browser toolbar.")

            ToolbarPreviewBar(
                showBack: toolbarShowBack,
                showForward: toolbarShowForward,
                showReload: toolbarShowReload,
                showReaderMode: toolbarShowReaderMode,
                showSmartRead: toolbarShowSmartRead,
                showClipboard: toolbarShowClipboard,
                showTabRailToggle: toolbarShowTabRailToggle,
                showChatToggle: toolbarShowChatToggle
            )

            section("Navigation") {
                ToolbarToggleRow(
                    symbol: "chevron.left",
                    label: "Back",
                    help: "Step back through this tab's history.",
                    isOn: $toolbarShowBack
                )
                ToolbarToggleRow(
                    symbol: "chevron.right",
                    label: "Forward",
                    help: "Step forward through this tab's history.",
                    isOn: $toolbarShowForward
                )
                ToolbarToggleRow(
                    symbol: "arrow.clockwise",
                    label: "Reload",
                    help: "Reload the current page (becomes Stop while a page is loading).",
                    isOn: $toolbarShowReload
                )
            }

            section("Tools") {
                ToolbarToggleRow(
                    symbol: "book.fill",
                    label: "Reader Mode",
                    help: "Strip an article down to a clean reading view. Only appears on article pages.",
                    isOn: $toolbarShowReaderMode
                )
                ToolbarToggleRow(
                    symbol: "text.magnifyingglass",
                    label: "Smart Read",
                    help: "Summarize the current page near your cursor. Only appears on article pages.",
                    isOn: $toolbarShowSmartRead
                )
                ToolbarToggleRow(
                    symbol: "doc.on.clipboard",
                    label: "Paste with citation",
                    help: "Open the clipboard history popover.",
                    isOn: $toolbarShowClipboard
                )
                ToolbarToggleRow(
                    symbol: "sidebar.left",
                    label: "Side tabs",
                    help: "Toggle the vertical tab rail.",
                    isOn: $toolbarShowTabRailToggle
                )
                ToolbarToggleRow(
                    symbol: "sparkles",
                    label: "AI chat",
                    help: "Toggle the AI chat panel.",
                    isOn: $toolbarShowChatToggle
                )
            }
        }
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "General", subtitle: "Search, surface, and defaults.")

            section("Web search") {
                row(label: "Fallback engine", help: "Used when an entry isn't a URL.") {
                    SegmentPicker(selection: $searchEngine, options: SearchEngine.allCases.map { ($0.rawValue, $0.displayName) })
                }
            }

            section("Notifications") {
                row(label: "Position", help: "Where toast notifications appear in the window.") {
                    SegmentPicker(
                        selection: $notificationCorner,
                        options: NotificationCorner.allCases.map { ($0.rawValue, $0.displayName) }
                    )
                }

                row(label: "Preview", help: "Send a sample notification to the selected corner.") {
                    HStack {
                        Spacer()
                        Button("Send test") {
                            AppNotificationCenter.shared.post(
                                title: "Test notification",
                                message: "This is what your notifications will look like.",
                                kind: .info
                            )
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            }

            section("Hover preview") {
                row(label: "Enable", help: "Show a preview panel when you hold the modifier over any link.") {
                    HStack {
                        Spacer()
                        ToggleSwitch(isOn: $hoverPreviewEnabled)
                    }
                }
                row(label: "Modifier", help: "Held while hovering a link to summon the preview.") {
                    SegmentPicker(
                        selection: $hoverPreviewModifier,
                        options: HoverPreviewModifier.allCases.map { ($0.rawValue, $0.displayName) }
                    )
                }
                row(label: "Hover delay", help: "Milliseconds the modifier must be held over a link before the panel appears.") {
                    NumericStepperField(value: $hoverPreviewDelayMs, range: 50...1500, step: 50, suffix: "ms")
                }
                row(label: "Prefetch delay", help: "Milliseconds of plain hover before we quietly cache a preview.") {
                    NumericStepperField(value: $hoverPreviewPrefetchDelayMs, range: 200...3000, step: 100, suffix: "ms")
                }
                row(label: "Prefetch blocklist", help: "One domain per line. Prefix with *. to match subdomains.") {
                    MultilineField(text: $hoverPreviewBlocklist, height: 84)
                }
            }

            section("Data") {
                row(label: "Chat history", help: "Removes every stored conversation from disk.") {
                    HStack {
                        Spacer()
                        DestructiveButton(title: "Clear all") {
                            showClearAllConfirm = true
                        }
                    }
                }
            }
        }
        .alert("Clear all chat history?", isPresented: $showClearAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { ChatSessionStore.shared.clearAll() }
        } message: {
            Text("This permanently deletes every saved conversation under ~/.thebrowser/sessions. Open chats stay until you start a new conversation.")
        }
    }

    // MARK: - AI

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "AI Engine", subtitle: "The command-line model that powers chat.")

            section("Provider") {
                row(label: "Backend", help: "Which CLI model answers your prompts.") {
                    SegmentPicker(selection: $aiProvider, options: AIProviderKind.allCases.map { ($0.rawValue, $0.displayName) })
                }

                row(label: "CLI path") {
                    MonoTextField(text: currentCLIPathBinding, placeholder: "Provider CLI path")
                }
            }

            section("Behavior") {
                row(label: "Model") {
                    PlainTextField(text: $aiModel, placeholder: "Provider default")
                }

                row(label: "System prompt", help: "Replaces the provider's default prompt.") {
                    MultilineField(text: $aiSystemPrompt, height: 108, isReadOnly: true)
                }

                if provider == .codex {
                    row(label: "Sandbox") {
                        SegmentPicker(selection: $codexSandbox, options: [
                            ("read-only", "Read"),
                            ("workspace-write", "Write"),
                            ("danger-full-access", "Full")
                        ])
                    }
                }

                row(label: "Extra args", help: "Passed before The Browser's replacement controls.") {
                    MultilineField(text: $aiExtraArguments, height: 70)
                }

                row(label: "Tool chain", help: "Show the row of native browser tools the model called for each answer.") {
                    HStack {
                        Spacer()
                        ToggleSwitch(isOn: $aiShowToolChain)
                    }
                }
            }

            if provider == .claude {
                section("Claude tool surface") {
                    row(label: "Tools", help: "Leave blank to disable Claude's default tools.") {
                        PlainTextField(text: $aiTools, placeholder: "Bash,Edit,Read")
                    }

                    row(label: "Auto-approve") {
                        PlainTextField(text: $aiAllowedTools, placeholder: "Bash(git *),Read,Edit")
                    }

                    row(label: "Deny tools") {
                        PlainTextField(text: $aiDisallowedTools, placeholder: "Bash(rm *),Edit")
                    }

                    row(label: "MCP config") {
                        MonoTextField(text: $aiMCPConfigPath, placeholder: "Path to MCP JSON config")
                    }
                }
            }
        }
    }

    // MARK: - Keybindings

    private var keybindingsSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "Keybindings", subtitle: "Click a row, then press the chord.")

            section("Browser") {
                row(label: "Toggle AI chat") { ShortcutRecorder(value: $toggleChatShortcut) }
                row(label: "Toggle side tabs") { ShortcutRecorder(value: $toggleTabsShortcut) }
                row(label: "New tab") { ShortcutRecorder(value: $newTabShortcut) }
                row(label: "Close tab") { ShortcutRecorder(value: $closeTabShortcut) }
                row(label: "Focus address") { ShortcutRecorder(value: $focusAddressShortcut) }
                row(label: "Smart Read", help: "Summarizes the current website near your cursor.") {
                    ShortcutRecorder(value: $smartReadShortcut)
                }
                row(label: "Reader Mode", help: "Transforms the current article into a clean, dark reading view.") {
                    ShortcutRecorder(value: $readerModeShortcut)
                }
                row(label: "Paste with citation", help: "Opens the clipboard history popover.") {
                    ShortcutRecorder(value: $pasteWithCitationShortcut)
                }
            }
        }
    }

    // MARK: - Migration

    private var migrationSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            MigrationView(presentation: .settings)
                .frame(minHeight: 540)
        }
    }

    // MARK: - Building blocks

    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)
                .padding(.bottom, 10)

            SectionList(content: content)
        }
    }

    @ViewBuilder
    private func row<Content: View>(label: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let help {
                    Text(help)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 160, alignment: .leading)
            .padding(.vertical, 14)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Bindings

    private var provider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? .codex
    }

    private var currentCLIPathBinding: Binding<String> {
        switch provider {
        case .codex:
            return $codexCLIPath
        case .claude:
            return $claudeCLIPath
        }
    }
}

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case toolbar
    case ai
    case clipboard
    case keybindings
    case migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .account: "Account"
        case .toolbar: "Toolbar"
        case .ai: "AI Engine"
        case .clipboard: "Clipboard"
        case .keybindings: "Keybindings"
        case .migration: "Migration"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .account: "person.crop.circle"
        case .toolbar: "square.topthird.inset.filled"
        case .ai: "sparkles"
        case .clipboard: "doc.on.clipboard"
        case .keybindings: "keyboard"
        case .migration: "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .frame(width: 16)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundFill)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.hoverFade, value: selected)
    }

    private var backgroundFill: Color {
        if selected { return Color.white.opacity(0.08) }
        if isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }
}

// MARK: - Form controls

private struct SegmentPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                SegmentChip(
                    label: option.1,
                    selected: option.0 == selection,
                    action: { selection = option.0 }
                )
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct SegmentChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundFill)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }

    private var backgroundFill: Color {
        if selected { return Color.white }
        if isHovering { return Color.white.opacity(0.06) }
        return Color.clear
    }
}

private struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(red: 0.85, green: 0.3, blue: 0.3).opacity(isHovering ? 0.55 : 0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var backgroundFill: Color {
        if isHovering { return Color(red: 0.7, green: 0.2, blue: 0.2).opacity(0.18) }
        return Color(red: 0.7, green: 0.2, blue: 0.2).opacity(0.10)
    }
}

/// Compact pill switch in the project's monochrome palette. Matches the
/// existing `SegmentPicker` chrome (1px hairline, `bgRaised` plate) so toggle
/// rows sit flush next to segmented controls in the same section card.
private struct ToggleSwitch: View {
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.white : Palette.bgRaised)
                    .frame(width: 38, height: 22)
                    .overlay {
                        Capsule().stroke(isOn ? Color.clear : Palette.stroke, lineWidth: 1)
                    }

                Circle()
                    .fill(isOn ? Palette.bg : Palette.textSecondary)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(Motion.springSnap, value: isOn)
            .animation(Motion.hoverFade, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One row in the Toolbar settings list. Combines a tinted icon chip, the
/// button's name and help text, and a `ToggleSwitch` — the row dims when off
/// so the toolbar preview above stays the primary readout of current state.
private struct ToolbarToggleRow: View {
    let symbol: String
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? Palette.surface : Palette.bgRaised.opacity(0.6))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isOn ? Palette.stroke : Palette.strokeFaint, lineWidth: 1)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.textPrimary : Palette.textMuted)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
                Text(help)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            ToggleSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .animation(Motion.springSnap, value: isOn)
    }
}

/// Live mini-rendering of the toolbar that reflects the current toggle state.
/// Mimics the actual `BrowserToolbar` layout (nav cluster, address bar, right
/// cluster) at reduced scale so users can see the effect of their choices
/// without leaving the settings page.
private struct ToolbarPreviewBar: View {
    let showBack: Bool
    let showForward: Bool
    let showReload: Bool
    let showReaderMode: Bool
    let showSmartRead: Bool
    let showClipboard: Bool
    let showTabRailToggle: Bool
    let showChatToggle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if showBack { previewChip("chevron.left") }
                        if showForward { previewChip("chevron.right") }
                        if showReload { previewChip("arrow.clockwise") }
                    }

                    previewAddressBar

                    HStack(spacing: 4) {
                        if showReaderMode { previewChip("book.fill") }
                        if showSmartRead { previewChip("text.magnifyingglass") }
                        if showClipboard { previewChip("doc.on.clipboard") }
                        if showTabRailToggle { previewChip("sidebar.left") }
                        if showChatToggle { previewChip("sparkles") }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Palette.stroke)
                    .frame(height: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.bg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.springSnap, value: stateID)
        }
    }

    private var previewAddressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Capsule()
                .fill(Palette.textFaint)
                .frame(height: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func previewChip(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.6).combined(with: .opacity),
                removal: .scale(scale: 0.6).combined(with: .opacity)
            ))
    }

    /// Packs all toggles into a single bitmask so the parent `.animation`
    /// fires once per state change, giving inserted/removed icons a coherent
    /// spring instead of competing per-icon animations.
    private var stateID: Int {
        var bits = 0
        if showBack { bits |= 1 << 0 }
        if showForward { bits |= 1 << 1 }
        if showReload { bits |= 1 << 2 }
        if showReaderMode { bits |= 1 << 3 }
        if showSmartRead { bits |= 1 << 4 }
        if showClipboard { bits |= 1 << 5 }
        if showTabRailToggle { bits |= 1 << 6 }
        if showChatToggle { bits |= 1 << 7 }
        return bits
    }
}

private struct PlainTextField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.textPrimary)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: focused)
    }
}

private struct MonoTextField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: focused)
    }
}

/// Compact `Int` stepper for short numeric values (delays, counts). Renders
/// the value next to ± chips so a single row fits a number, its unit, and
/// the controls without a SwiftUI Stepper's full Cocoa chrome.
private struct NumericStepperField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var suffix: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minWidth: 40, alignment: .trailing)
                Text(suffix)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }

            HStack(spacing: 4) {
                NumericStepChip(symbol: "minus") {
                    let next = value - step
                    value = max(range.lowerBound, next)
                }
                NumericStepChip(symbol: "plus") {
                    let next = value + step
                    value = min(range.upperBound, next)
                }
            }
        }
    }
}

private struct NumericStepChip: View {
    let symbol: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct MultilineField: View {
    @Binding var text: String
    var height: CGFloat
    var isReadOnly: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(isReadOnly ? Palette.textSecondary : Palette.textPrimary)
            .focused($focused)
            .disabled(isReadOnly)
            .frame(height: height)
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: focused)
    }
}

// Wraps section children in a card with hairline dividers between (not after) each row.
private struct SectionList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(SectionListRoot()) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct SectionListRoot: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.stroke)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
                child
            }
        }
    }
}
