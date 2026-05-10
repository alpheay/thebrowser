import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiWorkspacePath) private var aiWorkspacePath = AppDefaults.defaultWorkspacePath()
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @AppStorage(PreferenceKey.aiSystemPrompt) private var aiSystemPrompt = AppDefaults.defaultAISystemPrompt
    @AppStorage(PreferenceKey.aiTools) private var aiTools = ""
    @AppStorage(PreferenceKey.aiAllowedTools) private var aiAllowedTools = ""
    @AppStorage(PreferenceKey.aiDisallowedTools) private var aiDisallowedTools = ""
    @AppStorage(PreferenceKey.aiMCPConfigPath) private var aiMCPConfigPath = ""
    @AppStorage(PreferenceKey.aiExtraArguments) private var aiExtraArguments = ""
    @AppStorage(PreferenceKey.codexCLIPath) private var codexCLIPath = AppDefaults.defaultCodexCLIPath()
    @AppStorage(PreferenceKey.codexSandbox) private var codexSandbox = "read-only"
    @AppStorage(PreferenceKey.claudeCLIPath) private var claudeCLIPath = AppDefaults.defaultClaudeCLIPath()
    @AppStorage(PreferenceKey.searchEngine) private var searchEngine = SearchEngine.defaultValue.rawValue
    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"
    @AppStorage(PreferenceKey.newTabShortcut) private var newTabShortcut = "command+t"
    @AppStorage(PreferenceKey.closeTabShortcut) private var closeTabShortcut = "command+w"
    @AppStorage(PreferenceKey.focusAddressShortcut) private var focusAddressShortcut = "command+l"

    @State private var selectedTab: SettingsTab = .general

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
        case .ai:
            aiSettings
        case .keybindings:
            keybindingsSettings
        case .migration:
            migrationSettings
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
        }
    }

    // MARK: - AI

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader(title: "AI Harness", subtitle: "The command-line agent that powers chat.")

            section("Provider") {
                row(label: "Backend", help: "Which CLI agent answers your prompts.") {
                    SegmentPicker(selection: $aiProvider, options: AIProviderKind.allCases.map { ($0.rawValue, $0.displayName) })
                }

                row(label: "CLI path") {
                    MonoTextField(text: currentCLIPathBinding, placeholder: "Provider CLI path")
                }

                row(label: "Workspace") {
                    MonoTextField(text: $aiWorkspacePath, placeholder: "Workspace path")
                }
            }

            section("Behavior") {
                row(label: "Model") {
                    PlainTextField(text: $aiModel, placeholder: "Provider default")
                }

                row(label: "System prompt", help: "Prepended to every conversation.") {
                    MultilineField(text: $aiSystemPrompt, height: 108)
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

                row(label: "Extra args", help: "Passed to the CLI invocation.") {
                    MultilineField(text: $aiExtraArguments, height: 70)
                }
            }

            if provider == .claude {
                section("Claude tools") {
                    row(label: "Tools") {
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
    case ai
    case keybindings
    case migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .ai: "AI Harness"
        case .keybindings: "Keybindings"
        case .migration: "Migration"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .ai: "sparkles"
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

private struct MultilineField: View {
    @Binding var text: String
    var height: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .focused($focused)
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
