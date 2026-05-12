import SwiftUI

/// "Bookmarks" pane in Settings. Mirrors the section/row scaffolding used
/// by ``CitedClipboardSettingsContent`` so the page feels native next to
/// the other settings tabs.
struct BookmarksSettingsContent: View {
    @AppStorage(PreferenceKey.bookmarksAutoTagEnabled) private var autoTagEnabled = true
    @AppStorage(PreferenceKey.bookmarksTaggingModel) private var taggingModel = ""
    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @ObservedObject private var manager = BookmarksManager.shared

    @State private var retagConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            pageHeader

            section("Auto-tagging") {
                row(label: "Enable", help: "When on, new bookmarks are sent to the AI provider for 3–5 short tags and a 1–2 sentence description.") {
                    HStack { Spacer(); BookmarksToggle(isOn: $autoTagEnabled) }
                }

                row(label: "Model", help: "Override the model used for tagging. Leave blank to use the provider's fast model (Haiku 4.5 for Claude, GPT-5.4 Mini for Codex).") {
                    PlainModelField(text: $taggingModel, placeholder: defaultModelPlaceholder)
                }

                row(label: "Re-tag library", help: "Clear every existing tag + description and re-run the tagger across all saved bookmarks. Useful after switching models.") {
                    HStack {
                        Spacer()
                        Button("Re-tag all bookmarks") {
                            retagConfirm = true
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                }
            }

            section("Library") {
                row(label: "Saved bookmarks", help: "Persisted at ~/.thebrowser/bookmarks.sqlite.") {
                    HStack {
                        Spacer()
                        Text("\(manager.bookmarks.count)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
                if manager.migrationBackfill.isRunning {
                    row(label: "Backfill", help: "AI tagging is enriching your migrated bookmarks. The browser stays usable while this runs.") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text(manager.migrationBackfill.progressLabel)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.textMuted)
                            Spacer()
                        }
                    }
                }
            }
        }
        .alert("Re-tag every bookmark?", isPresented: $retagConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Re-tag", role: .destructive) {
                manager.retagAll()
            }
        } message: {
            Text("Existing tags and descriptions are cleared. The tagger runs in the background and your bookmarks remain usable while it works.")
        }
    }

    // MARK: - Bindings + helpers

    private var defaultModelPlaceholder: String {
        let provider = AIProviderKind(rawValue: aiProvider) ?? .codex
        return "Provider default (\(provider.fastModelID))"
    }

    // MARK: - Building blocks (mirror SettingsView's private builders)

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bookmarks")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("Smart bookmarks tag and summarize each page so you can find it later.")
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

            VStack(spacing: 0) {
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
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
                .padding(.leading, 16)
                .opacity(label == "Enable" || label == "Saved bookmarks" ? 0 : 1)
        }
    }
}

private struct BookmarksToggle: View {
    @Binding var isOn: Bool

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
            .animation(Motion.springSnap, value: isOn)
        }
        .buttonStyle(.plain)
    }
}

private struct PlainModelField: View {
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
