import AppKit
import SwiftUI

/// Full-window gallery of every artifact the AI has generated. Mirrors the
/// shape of ``HistoryModalView`` — backdrop gradient, hero with a centered
/// search field and date-group pills — but the body is a thumbnail grid of
/// ``ArtifactCard``s instead of a timeline list.
@MainActor
struct ArtifactGalleryView: View {
    @ObservedObject var model: ArtifactGalleryModel

    /// Closes the modal. Wired to the X button and the Escape key.
    let onClose: () -> Void
    /// Opens the artifact in the active tab (or focuses an existing one).
    let onOpen: (URL) -> Void
    /// Opens the artifact in a fresh background tab (⌘-click / context menu).
    let onOpenInBackground: (URL) -> Void
    /// Reveals the underlying `.html` file in Finder.
    let onReveal: (URL) -> Void
    /// Deletes the artifact from disk.
    let onDelete: (ArtifactMetadata) -> Void
    /// Jumps to the chat session that produced the artifact.
    let onOpenChat: (ArtifactSessionRef) -> Void

    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)]

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                hero

                Rectangle()
                    .fill(Palette.strokeFaint)
                    .frame(height: 1)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.reload()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: ArtifactStore.didChangeNotification)) { _ in
            model.reload()
        }
        .background {
            ArtifactGalleryEscapeHandler(onEscape: onClose)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: Color(hex: 0x141414), location: 0),
                Gradient.Stop(color: Palette.bg, location: 0.34),
                Gradient.Stop(color: Palette.bg, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Artifacts")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }

                Spacer(minLength: 16)

                if !model.artifacts.isEmpty {
                    ArtifactStatChip(count: model.artifacts.count)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Close gallery")
            }
            .padding(.horizontal, 28)

            searchField
                .padding(.horizontal, 28)

            groupPills
                .padding(.horizontal, 28)
        }
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var headerSubtitle: String {
        if model.artifacts.isEmpty {
            return "Documents the AI builds for you will collect here."
        }
        let count = model.artifacts.count
        return "\(count) " + (count == 1 ? "artifact" : "artifacts") + " generated."
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchFocused ? Palette.textPrimary : Palette.textMuted)
            TextField("Search artifacts\u{2026}", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(searchFocused ? Color.white.opacity(0.06) : Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(searchFocused ? Color.white.opacity(0.22) : Palette.stroke, lineWidth: 1)
        }
        .shadow(color: searchFocused ? Color.black.opacity(0.45) : Color.clear, radius: 18, y: 6)
        .animation(Motion.springSnap, value: searchFocused)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var groupPills: some View {
        HStack(spacing: 6) {
            ForEach(HistoryDateGroup.allCases) { group in
                ArtifactDateGroupPill(
                    group: group,
                    count: model.countByGroup[group, default: 0],
                    selected: group == model.selectedGroup && model.trimmedQuery.isEmpty,
                    action: {
                        withAnimation(Motion.springSnap) {
                            model.selectedGroup = group
                            model.searchQuery = ""
                        }
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let artifacts = model.filteredArtifacts
        if !model.isLoaded {
            Color.clear
        } else if artifacts.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(artifacts) { artifact in
                        ArtifactCard(
                            artifact: artifact,
                            renderer: model.thumbnails,
                            onOpen: { open(artifact) },
                            onOpenInBackground: { onOpenInBackground(artifact.url) },
                            onReveal: { onReveal(artifact.url) },
                            onDelete: { onDelete(artifact) },
                            onOpenChat: {
                                if let session = artifact.session { onOpenChat(session) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Palette.surface).frame(width: 64, height: 64)
                Circle().stroke(Palette.stroke, lineWidth: 1).frame(width: 64, height: 64)
                if model.trimmedQuery.isEmpty {
                    ArtifactMark()
                        .foregroundStyle(Palette.textMuted)
                        .scaleEffect(1.7)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            VStack(spacing: 4) {
                Text(emptyTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(emptyHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
    }

    private var emptyTitle: String {
        if !model.trimmedQuery.isEmpty { return "No matches" }
        if model.artifacts.isEmpty { return "No artifacts yet" }
        return "Nothing in \(model.selectedGroup.title.lowercased())"
    }

    private var emptyHint: String {
        if !model.trimmedQuery.isEmpty {
            return "Try a different keyword or clear the search."
        }
        if model.artifacts.isEmpty {
            return "Ask the AI to build a report or dashboard and it will show up here."
        }
        return "Pick another span above to see more of your artifacts."
    }

    // MARK: - Actions

    private func open(_ artifact: ArtifactMetadata) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            onOpenInBackground(artifact.url)
        } else {
            onOpen(artifact.url)
        }
    }
}

// MARK: - Card

private struct ArtifactCard: View {
    let artifact: ArtifactMetadata
    let renderer: ArtifactThumbnailRenderer
    let onOpen: () -> Void
    let onOpenInBackground: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onOpenChat: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                footer
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isHovering ? Color.white.opacity(0.22) : Palette.stroke, lineWidth: 1)
            }
            .shadow(color: isHovering ? Color.black.opacity(0.4) : Color.clear, radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Open in new tab") { onOpenInBackground() }
            Button("Reveal in Finder") { onReveal() }
            Button("Copy link") { copyLink() }
            if artifact.session != nil {
                Divider()
                Button("Open originating chat") { onOpenChat() }
            }
            Divider()
            Button("Delete artifact", role: .destructive) { onDelete() }
        }
        .help(artifact.title)
    }

    private var thumbnail: some View {
        ArtifactThumbnailView(artifact: artifact, renderer: renderer)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(artifact.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(Self.relativeDate(from: artifact.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)

                if let session = artifact.session {
                    Text("\u{00B7}")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(sessionLabel(session))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(Palette.textMuted)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    private func sessionLabel(_ session: ArtifactSessionRef) -> String {
        let title = session.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "From chat" : title
    }

    private func copyLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(artifact.url.path, forType: .string)
    }

    private static func relativeDate(from date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Pills

private struct ArtifactDateGroupPill: View {
    let group: HistoryDateGroup
    let count: Int
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? Palette.bg.opacity(0.75) : Palette.textFaint)
            }
            .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule().fill(backgroundFill)
            }
            .overlay {
                Capsule().stroke(selected ? Color.clear : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }

    private var backgroundFill: Color {
        if selected { return Color.white }
        if isHovering { return Palette.surfaceHover }
        return Palette.surface
    }
}

private struct ArtifactStatChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.textPrimary.opacity(0.7))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background { Capsule().fill(Palette.surface) }
        .overlay { Capsule().stroke(Palette.stroke, lineWidth: 1) }
    }

    private var label: String {
        count == 1 ? "1 artifact" : "\(count.formatted(.number)) artifacts"
    }
}

// MARK: - Esc-to-dismiss bridge

/// Captures unmodified Escape key presses while the gallery is on screen —
/// the shell-level `KeyboardShortcutHost` ignores events without a modifier,
/// so the modal owns its own dismissal monitor (mirrors `HistoryEscapeHandler`).
private struct ArtifactGalleryEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(onEscape: @escaping () -> Void) {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    onEscape()
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
