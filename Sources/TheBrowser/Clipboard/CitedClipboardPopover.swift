import AppKit
import SwiftUI

/// Spotlight-style picker that the manual paste-with-citation shortcut
/// opens. Shows recent clips with a search filter; selecting one swaps
/// the row list for a small format submenu. Picking a format writes the
/// rendered text to the pasteboard and dismisses.
@MainActor
final class CitedClipboardPopoverModel: ObservableObject {
    @Published var clips: [CitedClip] = []
    @Published var search: String = ""
    @Published var selectedClipID: CitedClip.ID?
    @Published var pickedClip: CitedClip?
    @Published var copiedToast: String?

    private let store: CitedClipboardStore
    private let controller: CitedClipboardController
    /// `nonisolated(unsafe)` so the nonisolated deinit can hand the token
    /// back to NotificationCenter. The popover model is short-lived
    /// (rebuilt on each popover open), so deinit cleanup matters.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?

    init(
        store: CitedClipboardStore = CitedClipboardStore.shared,
        controller: CitedClipboardController = CitedClipboardController.shared
    ) {
        self.store = store
        self.controller = controller
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

    var filteredClips: [CitedClip] {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return clips }
        return clips.filter { clip in
            clip.text.lowercased().contains(trimmed)
                || clip.sourceLabel.lowercased().contains(trimmed)
                || clip.pageDomain.lowercased().contains(trimmed)
        }
    }

    func pick(_ clip: CitedClip) {
        pickedClip = clip
    }

    func backToList() {
        pickedClip = nil
    }

    func format(_ clip: CitedClip, as format: CitedClipFormat) {
        controller.paste(clip: clip, format: format)
        showToast("Copied — switch and ⌘V")
    }

    func recopy(_ clip: CitedClip) {
        controller.recopy(clip: clip)
        showToast("Re-copied — switch and ⌘V")
    }

    func reset() {
        pickedClip = nil
        search = ""
        selectedClipID = nil
        copiedToast = nil
        toastTask?.cancel()
    }

    private func showToast(_ message: String) {
        copiedToast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.18)) {
                    self?.copiedToast = nil
                }
            }
        }
    }
}

/// Compact, Spotlight-feeling picker. Lives inside a `.popover` anchored to
/// the small clipboard chip in ``BrowserToolbar``.
struct CitedClipboardPopover: View {
    @ObservedObject var model: CitedClipboardPopoverModel
    var onClose: () -> Void

    private static let popoverCornerRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 380)
        .frame(minHeight: 320, maxHeight: 460)
        .background(Palette.bgRaised)
        .overlay {
            RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous))
        .overlay(alignment: .bottom) {
            if let toast = model.copiedToast {
                Text(toast)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Palette.surfaceActive))
                    .overlay(Capsule().stroke(Palette.strokeStrong, lineWidth: 1))
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let pickedClip = model.pickedClip {
                backPill(for: pickedClip)
            } else {
                searchPill
            }

            CloseButton(action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var searchPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)

            TextField("Search clips…", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.strokeFaint, lineWidth: 1)
        }
    }

    private func backPill(for pickedClip: CitedClip) -> some View {
        Button {
            withAnimation(Motion.springSnap) { model.backToList() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                Text(pickedClip.sourceLabel.isEmpty ? "Clip" : pickedClip.sourceLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.strokeFaint, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Back to list")
    }

    @ViewBuilder
    private var content: some View {
        if let clip = model.pickedClip {
            FormatPicker(clip: clip) { format in
                model.format(clip, as: format)
                onClose()
            }
        } else if model.filteredClips.isEmpty {
            EmptyStateView(searchActive: !model.search.trimmingCharacters(in: .whitespaces).isEmpty)
        } else {
            ClipList(
                clips: model.filteredClips,
                onPick: { clip in
                    withAnimation(Motion.springSnap) { model.pick(clip) }
                },
                onRecopy: { clip in
                    model.recopy(clip)
                }
            )
        }
    }
}

private struct CloseButton: View {
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isHovering ? Palette.surfaceHover : Color.clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }
}

private struct ClipList: View {
    let clips: [CitedClip]
    var onPick: (CitedClip) -> Void
    var onRecopy: (CitedClip) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(clips) { clip in
                    ClipRow(
                        clip: clip,
                        onPick: { onPick(clip) },
                        onRecopy: { onRecopy(clip) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ClipRow: View {
    let clip: CitedClip
    var onPick: () -> Void
    var onRecopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.preview)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(clip.pageDomain.isEmpty ? clip.sourceLabel : clip.pageDomain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !clip.pageDomain.isEmpty {
                            Circle()
                                .fill(Palette.textFaint)
                                .frame(width: 2.5, height: 2.5)
                        }
                        Text(Self.relativeTimeFormatter.localizedString(for: clip.timestamp, relativeTo: Date()))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer(minLength: 4)

                Button(action: onRecopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 26, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.surface)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Palette.stroke, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Re-copy as-is")
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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

private struct FormatPicker: View {
    let clip: CitedClip
    var onPick: (CitedClipFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(clip.preview)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !clip.sourceLabel.isEmpty || !clip.sourceURL.isEmpty {
                    Text(clip.sourceLabel.isEmpty ? clip.sourceURL : clip.sourceLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)
                .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(CitedClipFormat.allCases) { format in
                        FormatRow(format: format, action: { onPick(format) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct FormatRow: View {
    let format: CitedClipFormat
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: format.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18)
                Text(format.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }
}

private struct EmptyStateView: View {
    var searchActive: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: searchActive ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 52, height: 52)
                .background {
                    Circle().fill(Palette.surface)
                }
                .overlay {
                    Circle().stroke(Palette.strokeFaint, lineWidth: 1)
                }

            VStack(spacing: 4) {
                Text(searchActive ? "No matches" : "No clips yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(searchActive
                     ? "Try a different keyword or clear the search."
                     : "Copy text from a web page to start a citation log.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }
}
