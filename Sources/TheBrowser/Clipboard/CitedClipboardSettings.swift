import SwiftUI

/// Settings view for the Cited Clipboard feature. Lives as its own SwiftUI
/// view so the main `SettingsView` stays focused on existing settings; just
/// the new `Clipboard` tab embeds this.
@MainActor
final class CitedClipboardSettingsModel: ObservableObject {
    @Published var clips: [CitedClip] = []

    private let store: CitedClipboardStore
    /// `nonisolated(unsafe)` so the nonisolated deinit can hand the token
    /// back to NotificationCenter — the model is rebuilt every time the
    /// Settings tab is shown.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(store: CitedClipboardStore = CitedClipboardStore.shared) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: CitedClipboardStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        clips = store.recentClips()
    }

    func delete(id: String) {
        store.delete(id: id)
    }

    func clearAll() {
        store.clearAll()
    }

    func recopy(_ clip: CitedClip) {
        CitedClipboardController.shared.recopy(clip: clip)
    }
}

struct CitedClipboardSettingsContent: View {
    @AppStorage(PreferenceKey.clipboardEnabled) private var clipboardEnabled = true
    @AppStorage(PreferenceKey.clipboardSmartPasteEnabled) private var smartPasteEnabled = true
    @AppStorage(PreferenceKey.clipboardMarkdownStyle) private var markdownStyle = CitedMarkdownStyle.blockquote.rawValue
    @AppStorage(PreferenceKey.clipboardCitationStyle) private var citationStyle = CitedCitationStyle.bracketed.rawValue
    @AppStorage(PreferenceKey.clipboardBlocklist) private var blocklist = CitedClipboardPolicy.defaultBlocklistString

    @StateObject private var model = CitedClipboardSettingsModel()
    @State private var showClearAllConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ClipboardPageHeader()

            ClipboardSection("Capture") {
                ClipboardRow(label: "Enable Cited Clipboard", help: "Capture web copies with source attribution.") {
                    HStack { Spacer(); ClipboardToggle(isOn: $clipboardEnabled) }
                }
            }

            ClipboardSection("Format") {
                ClipboardRow(label: "Markdown style", help: "Used by smart paste into markdown editors.") {
                    ClipboardSegment(
                        selection: $markdownStyle,
                        options: CitedMarkdownStyle.allCases.map { ($0.rawValue, $0.displayName) }
                    )
                }
                ClipboardRow(label: "Citation style", help: "Used in non-markdown destinations.") {
                    ClipboardSegment(
                        selection: $citationStyle,
                        options: CitedCitationStyle.allCases.map { ($0.rawValue, $0.displayName) }
                    )
                }
            }

            ClipboardSection("Smart paste") {
                ClipboardRow(label: "Rewrite on app activation", help: "Auto-format the clip when a known markdown app comes forward.") {
                    HStack { Spacer(); ClipboardToggle(isOn: $smartPasteEnabled) }
                }
                ClipboardRow(label: "Domain blocklist", help: "One host per line. Suffix-matched.") {
                    ClipboardMultiline(text: $blocklist, height: 120)
                }
            }

            ClipboardSection("History") {
                if model.clips.isEmpty {
                    ClipboardRow(label: "Recent clips", help: "Local-only, never synced.") {
                        Text("No clips yet — copy from a web page to start the log.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                    }
                } else {
                    ClipboardRow(label: "Recent clips", help: "Up to 200 newest entries. Local-only.") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(model.clips.count) clip\(model.clips.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.textMuted)
                                Spacer()
                                ClipboardDestructive(title: "Clear all") {
                                    showClearAllConfirm = true
                                }
                            }
                            VStack(spacing: 0) {
                                ForEach(model.clips) { clip in
                                    SettingsClipRow(
                                        clip: clip,
                                        onRecopy: { model.recopy(clip) },
                                        onDelete: { model.delete(id: clip.id) }
                                    )
                                    if clip.id != model.clips.last?.id {
                                        Rectangle()
                                            .fill(Palette.strokeFaint)
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Palette.bgRaised)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Palette.stroke, lineWidth: 1)
                            }
                        }
                    }
                }
            }
        }
        .alert("Clear all clipboard history?", isPresented: $showClearAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { model.clearAll() }
        } message: {
            Text("This permanently deletes every captured clip from ~/.thebrowser/clipboard.sqlite.")
        }
    }
}

private struct SettingsClipRow: View {
    let clip: CitedClip
    var onRecopy: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.preview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if !clip.pageDomain.isEmpty {
                        Text(clip.pageDomain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    } else if !clip.sourceLabel.isEmpty {
                        Text(clip.sourceLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(Self.relativeTimeFormatter.localizedString(for: clip.timestamp, relativeTo: Date()))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                    if !clip.sourceURL.isEmpty {
                        Text("·")
                            .foregroundStyle(Palette.textFaint)
                        Text(clip.sourceURL)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button(action: onRecopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Re-copy as-is")
                .opacity(isHovering ? 1 : 0.55)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete clip")
                .opacity(isHovering ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovering ? Palette.surfaceHover.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Local UI primitives
//
// Copied lightweight versions of the Settings building blocks instead of
// pulling them out of `SettingsView.swift` (where they're file-private). Same
// look + feel, scoped to the Clipboard tab. If we grow more tabs that need
// them, we can promote these into the design system.

private struct ClipboardPageHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clipboard")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("Capture-on-copy with source attribution.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }
}

private struct ClipboardSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
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
}

private struct ClipboardRow<Content: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
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
            // Divider above non-first rows.
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
                .padding(.leading, 16)
                .padding(.top, 0)
                .opacity(0)
        }
    }
}

private struct ClipboardToggle: View {
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

private struct ClipboardSegment: View {
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                ClipboardSegmentChip(
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

private struct ClipboardSegmentChip: View {
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
                        .fill(selected ? Color.white : (isHovering ? Color.white.opacity(0.06) : Color.clear))
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }
}

private struct ClipboardMultiline: View {
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

private struct ClipboardDestructive: View {
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
                        .fill(isHovering
                              ? Color(red: 0.7, green: 0.2, blue: 0.2).opacity(0.18)
                              : Color(red: 0.7, green: 0.2, blue: 0.2).opacity(0.10))
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
}
