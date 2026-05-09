import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.codexCLIPath) private var codexCLIPath = AppDefaults.defaultCodexCLIPath()
    @AppStorage(PreferenceKey.codexWorkspacePath) private var codexWorkspacePath = AppDefaults.defaultCodexWorkspacePath()
    @AppStorage(PreferenceKey.codexModel) private var codexModel = ""
    @AppStorage(PreferenceKey.codexSandbox) private var codexSandbox = "read-only"
    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.pearl)
                Text("Codex, shortcuts, and browser control surfaces.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }

            settingsSection("Codex CLI") {
                LabeledContent("CLI path") {
                    TextField("Codex CLI path", text: $codexCLIPath)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .glassPanel()
                }

                LabeledContent("Workspace") {
                    TextField("Workspace path", text: $codexWorkspacePath)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .glassPanel()
                }

                LabeledContent("Model") {
                    TextField("Default from Codex config", text: $codexModel)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .glassPanel()
                }

                LabeledContent("Sandbox") {
                    Picker("", selection: $codexSandbox) {
                        Text("Read Only").tag("read-only")
                        Text("Workspace Write").tag("workspace-write")
                        Text("Danger Full Access").tag("danger-full-access")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
            }

            settingsSection("Keybindings") {
                LabeledContent("Toggle AI chat") {
                    ShortcutRecorder(value: $toggleChatShortcut)
                }

                LabeledContent("Toggle side tabs") {
                    ShortcutRecorder(value: $toggleTabsShortcut)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .background(Palette.ink)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.saffron)
                .textCase(.uppercase)
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .glassPanel()
        }
    }
}
