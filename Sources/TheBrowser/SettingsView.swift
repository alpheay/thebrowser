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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("AI providers, shortcuts, and browser surfaces.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }

                section("Browser") {
                    settingRow("Web fallback") {
                        Picker("", selection: $searchEngine) {
                            ForEach(SearchEngine.allCases) { engine in
                                Text(engine.displayName).tag(engine.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                section("AI Harness") {
                    settingRow("Provider") {
                        Picker("", selection: $aiProvider) {
                            ForEach(AIProviderKind.allCases) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    settingRow("CLI path") {
                        TextField("Provider CLI path", text: currentCLIPathBinding)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

                    settingRow("Workspace") {
                        TextField("Workspace path", text: $aiWorkspacePath)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

                    settingRow("Model") {
                        TextField("Provider default", text: $aiModel)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

                    settingRow("System prompt") {
                        multilineEditor(text: $aiSystemPrompt, height: 108)
                    }

                    if provider == .claude {
                        settingRow("Tools") {
                            TextField("Bash,Edit,Read", text: $aiTools)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .surfaceCard(radius: 8)
                        }

                        settingRow("Auto-approve") {
                            TextField("Bash(git *),Read,Edit", text: $aiAllowedTools)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .surfaceCard(radius: 8)
                        }

                        settingRow("Deny tools") {
                            TextField("Bash(rm *),Edit", text: $aiDisallowedTools)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .surfaceCard(radius: 8)
                        }

                        settingRow("MCP config") {
                            TextField("Path to MCP JSON config", text: $aiMCPConfigPath)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .surfaceCard(radius: 8)
                        }
                    }

                    if provider == .codex {
                        settingRow("Sandbox") {
                            Picker("", selection: $codexSandbox) {
                                Text("Read Only").tag("read-only")
                                Text("Workspace Write").tag("workspace-write")
                                Text("Danger Full Access").tag("danger-full-access")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    settingRow("Extra args") {
                        multilineEditor(text: $aiExtraArguments, height: 70)
                    }
                }

                section("Keybindings") {
                    settingRow("Toggle AI chat") {
                        ShortcutRecorder(value: $toggleChatShortcut)
                    }
                    settingRow("Toggle side tabs") {
                        ShortcutRecorder(value: $toggleTabsShortcut)
                    }
                    settingRow("New tab") {
                        ShortcutRecorder(value: $newTabShortcut)
                    }
                    settingRow("Close tab") {
                        ShortcutRecorder(value: $closeTabShortcut)
                    }
                    settingRow("Focus address") {
                        ShortcutRecorder(value: $focusAddressShortcut)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bg)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textMuted)
                Rectangle()
                    .fill(Palette.stroke)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 8)
                .frame(width: 140, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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

    private func multilineEditor(text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .scrollContentBackground(.hidden)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.textPrimary)
            .frame(height: height)
            .padding(8)
            .surfaceCard(radius: 8)
    }
}
