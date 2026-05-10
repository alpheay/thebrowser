import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.codexCLIPath) private var codexCLIPath = AppDefaults.defaultCodexCLIPath()
    @AppStorage(PreferenceKey.codexWorkspacePath) private var codexWorkspacePath = AppDefaults.defaultCodexWorkspacePath()
    @AppStorage(PreferenceKey.codexModel) private var codexModel = ""
    @AppStorage(PreferenceKey.codexSandbox) private var codexSandbox = "read-only"
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
                    Text("Codex, shortcuts, and browser surfaces.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }

                section("Codex CLI") {
                    settingRow("CLI path") {
                        TextField("Codex CLI path", text: $codexCLIPath)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

                    settingRow("Workspace") {
                        TextField("Workspace path", text: $codexWorkspacePath)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

                    settingRow("Model") {
                        TextField("Default from Codex config", text: $codexModel)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .surfaceCard(radius: 8)
                    }

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
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 140, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
