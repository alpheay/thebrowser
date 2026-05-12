import AppKit
import SwiftUI

/// Spotlight-style picker that the manual paste-with-citation shortcut
/// opens. Two modes coexist:
///
/// - Single-clip paste: tap a row, pick a citation format, copy.
/// - Draft from clips: check 1+ rows, pick a preset (note / email / argument
///   / bug report / research summary / custom), and the AI provider returns
///   a markdown draft with `[N]` inline citations + a `## Sources` list.
@MainActor
final class CitedClipboardPopoverModel: ObservableObject {
    /// One-of-N view state. Selection and search persist across mode
    /// transitions; only the rendered content swaps.
    enum Mode: Equatable {
        case list
        case formatPicker(CitedClip)
        case draftCompose
        case drafting
        case draftSurface
    }

    @Published var clips: [CitedClip] = []
    @Published var search: String = ""
    @Published var mode: Mode = .list
    @Published var selectedClipIDs: Set<CitedClip.ID> = []

    @Published var draftPreset: CitedClipDraftPreset = .note
    @Published var customInstruction: String = ""
    /// The drafted markdown. Owned by the model (not the view) so it
    /// survives back/forward inside the popover; cleared on `reset()`.
    @Published var draftOutput: String = ""
    /// Snapshot of the clips used for the current draft, captured at
    /// generation time so the citations list in the rendered surface
    /// matches the `[N]` indices even if the user changes their selection
    /// between generation and copy.
    @Published var draftSources: [CitedClip] = []
    @Published var draftError: String?

    @Published var copiedToast: String?

    private let store: CitedClipboardStore
    private let controller: CitedClipboardController
    private let draftService: CitedClipDraftService
    /// `nonisolated(unsafe)` so the nonisolated deinit can hand the token
    /// back to NotificationCenter. The popover model is short-lived
    /// (rebuilt on each popover open), so deinit cleanup matters.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?

    init(
        store: CitedClipboardStore = CitedClipboardStore.shared,
        controller: CitedClipboardController = CitedClipboardController.shared,
        draftService: CitedClipDraftService = CitedClipDraftService()
    ) {
        self.store = store
        self.controller = controller
        self.draftService = draftService
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
        // Drop any selection ids that no longer exist in the store
        // (clip was deleted or aged off the 200-clip cap).
        if !selectedClipIDs.isEmpty {
            let valid = Set(clips.map(\.id))
            selectedClipIDs = selectedClipIDs.intersection(valid)
        }
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

    var hasSelection: Bool { !selectedClipIDs.isEmpty }

    /// Selected clips in newest-first order, mirroring the displayed list
    /// — so the `[N]` indices the model produces line up with the order
    /// the user sees in the source footer.
    var selectedClips: [CitedClip] {
        clips.filter { selectedClipIDs.contains($0.id) }
    }

    // MARK: - List + format picker

    func toggleSelection(_ clip: CitedClip) {
        if selectedClipIDs.contains(clip.id) {
            selectedClipIDs.remove(clip.id)
        } else {
            selectedClipIDs.insert(clip.id)
        }
    }

    func clearSelection() {
        selectedClipIDs.removeAll()
    }

    func pickForFormat(_ clip: CitedClip) {
        mode = .formatPicker(clip)
    }

    func backToList() {
        mode = .list
    }

    func format(_ clip: CitedClip, as format: CitedClipFormat) {
        controller.paste(clip: clip, format: format)
        showToast("Copied — switch and ⌘V")
    }

    func recopy(_ clip: CitedClip) {
        controller.recopy(clip: clip)
        showToast("Re-copied — switch and ⌘V")
    }

    // MARK: - Draft flow

    func openDraftCompose() {
        guard hasSelection else { return }
        draftError = nil
        mode = .draftCompose
    }

    func cancelDraftCompose() {
        mode = .list
    }

    func generateDraft() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }

        draftError = nil
        draftOutput = ""
        draftSources = clips
        mode = .drafting

        draftTask?.cancel()
        let preset = draftPreset
        let custom = customInstruction
        let service = draftService
        draftTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.draft(
                    clips: clips,
                    preset: preset,
                    customInstruction: custom
                )
                try Task.checkCancellation()
                guard let self else { return }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.draftError = "The provider returned an empty draft. Try again."
                    self.mode = .draftCompose
                } else {
                    self.draftOutput = trimmed
                    self.mode = .draftSurface
                }
            } catch is CancellationError {
                // Cancellation flips the mode back via `cancelDraftRun()`.
            } catch {
                guard let self else { return }
                self.draftError = error.localizedDescription
                self.mode = .draftCompose
            }
        }
    }

    func cancelDraftRun() {
        draftTask?.cancel()
        draftTask = nil
        mode = .draftCompose
    }

    func copyDraft() {
        let text = draftOutput
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("Draft copied — switch and ⌘V")
    }

    func regenerateDraft() {
        draftError = nil
        mode = .draftCompose
    }

    func discardDraft() {
        draftOutput = ""
        draftSources = []
        draftError = nil
        mode = .list
    }

    func reset() {
        draftTask?.cancel()
        draftTask = nil
        toastTask?.cancel()
        toastTask = nil
        mode = .list
        search = ""
        selectedClipIDs.removeAll()
        customInstruction = ""
        draftPreset = .note
        draftOutput = ""
        draftSources = []
        draftError = nil
        copiedToast = nil
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
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(Palette.bgRaised)
        .overlay {
            RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous))
        .animation(Motion.springSoft, value: model.mode)
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

    /// Heights vary by mode so the writing surface gets room to breathe
    /// without making the list view feel oversized.
    private var minHeight: CGFloat {
        switch model.mode {
        case .list, .formatPicker: return 320
        case .draftCompose: return 360
        case .drafting: return 220
        case .draftSurface: return 540
        }
    }

    private var maxHeight: CGFloat {
        switch model.mode {
        case .list, .formatPicker: return 460
        case .draftCompose: return 480
        case .drafting: return 260
        case .draftSurface: return 600
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            switch model.mode {
            case .list:
                searchPill
            case .formatPicker(let clip):
                backPill(label: clip.sourceLabel.isEmpty ? "Clip" : clip.sourceLabel, action: { model.backToList() })
            case .draftCompose:
                let count = model.selectedClipIDs.count
                backPill(label: "Draft from \(count) clip\(count == 1 ? "" : "s")", action: { model.cancelDraftCompose() })
            case .drafting:
                backPill(label: "Drafting…", action: { model.cancelDraftRun() })
            case .draftSurface:
                draftSurfaceTitlePill
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

    private func backPill(label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.springSnap) { action() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                Text(label)
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
        .help("Back")
    }

    /// The draft surface header is non-interactive — back routes through the
    /// footer's Discard button, so the user doesn't accidentally lose a draft
    /// by tapping the chevron.
    private var draftSurfaceTitlePill: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text(model.draftPreset.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text("• \(model.draftSources.count) source\(model.draftSources.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
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
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .formatPicker(let clip):
            FormatPicker(clip: clip) { format in
                model.format(clip, as: format)
                onClose()
            }
        case .draftCompose:
            DraftComposeView(model: model)
        case .drafting:
            DraftingView(model: model)
        case .draftSurface:
            DraftSurfaceView(model: model, onCopyAndClose: {
                model.copyDraft()
                onClose()
            })
        case .list:
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if model.filteredClips.isEmpty {
            EmptyStateView(searchActive: !model.search.trimmingCharacters(in: .whitespaces).isEmpty)
        } else {
            VStack(spacing: 0) {
                ClipList(
                    clips: model.filteredClips,
                    selectedIDs: model.selectedClipIDs,
                    onPick: { clip in
                        withAnimation(Motion.springSnap) { model.pickForFormat(clip) }
                    },
                    onToggleSelect: { clip in
                        withAnimation(Motion.springSnap) { model.toggleSelection(clip) }
                    },
                    onRecopy: { clip in
                        model.recopy(clip)
                    }
                )

                if model.hasSelection {
                    SelectionFooter(
                        count: model.selectedClipIDs.count,
                        onClear: { withAnimation(Motion.springSnap) { model.clearSelection() } },
                        onDraft: { withAnimation(Motion.springSnap) { model.openDraftCompose() } }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
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
    let selectedIDs: Set<CitedClip.ID>
    var onPick: (CitedClip) -> Void
    var onToggleSelect: (CitedClip) -> Void
    var onRecopy: (CitedClip) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(clips) { clip in
                    ClipRow(
                        clip: clip,
                        isSelected: selectedIDs.contains(clip.id),
                        onPick: { onPick(clip) },
                        onToggleSelect: { onToggleSelect(clip) },
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
    let isSelected: Bool
    var onPick: () -> Void
    var onToggleSelect: () -> Void
    var onRecopy: () -> Void

    @State private var isHovering = false

    /// The checkbox is always present when the row is selected (so the
    /// state is visible at rest) and fades in on hover otherwise.
    private var showCheckbox: Bool { isSelected || isHovering }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                SelectCheckbox(isSelected: isSelected, action: onToggleSelect)
                    .opacity(showCheckbox ? 1 : 0)
                    .allowsHitTesting(showCheckbox)
                    .frame(width: 18)

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
                    .fill(rowFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private var rowFill: Color {
        if isSelected { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

private struct SelectCheckbox: View {
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Palette.accent : Color.clear)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isSelected ? Palette.accent : Palette.strokeStrong, lineWidth: 1.2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Palette.bg)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Remove from draft selection" : "Add to draft selection")
    }
}

private struct SelectionFooter: View {
    let count: Int
    var onClear: () -> Void
    var onDraft: () -> Void

    @State private var draftHover = false
    @State private var clearHover = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count) selected")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: 4)

            Button(action: onClear) {
                Text("Clear")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(clearHover ? Palette.surfaceHover : Color.clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(Motion.hoverFade) { clearHover = hovering }
            }

            Button(action: onDraft) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Draft from \(count)")
                        .font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Palette.bg)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(draftHover ? Color.white : Palette.accent)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(Motion.hoverFade) { draftHover = hovering }
            }
            .help("Draft a note, email, or summary from these clips")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Rectangle()
                .fill(Palette.bgSunken)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
        }
    }
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

// MARK: - Draft compose / drafting / surface

private struct DraftComposeView: View {
    @ObservedObject var model: CitedClipboardPopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.draftError {
                        ErrorBanner(message: error)
                    }

                    selectedClipsSummary

                    Text("Pick a format")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    presetGrid

                    if model.draftPreset == .custom {
                        customInstructionField
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)

            footer
        }
    }

    private var selectedClipsSummary: some View {
        let clips = model.selectedClips
        let preview = clips.prefix(3).map(\.sourceLabel).filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(summaryText(clips: clips, preview: preview))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func summaryText(clips: [CitedClip], preview: [String]) -> String {
        guard !clips.isEmpty else { return "No clips selected." }
        if preview.isEmpty {
            return "\(clips.count) clip\(clips.count == 1 ? "" : "s") selected."
        }
        if clips.count <= preview.count {
            return preview.joined(separator: " · ")
        }
        let remaining = clips.count - preview.count
        return preview.joined(separator: " · ") + " · +\(remaining) more"
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(CitedClipDraftPreset.allCases) { preset in
                PresetTile(
                    preset: preset,
                    isSelected: model.draftPreset == preset,
                    action: { model.draftPreset = preset }
                )
            }
        }
    }

    private var customInstructionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Instruction")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .textCase(.uppercase)
                .tracking(0.4)
            TextEditor(text: $model.customInstruction)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 60, maxHeight: 90)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.strokeFaint, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if model.customInstruction.isEmpty {
                        Text("e.g. \u{201C}Two paragraphs, casual tone, ready to send to the team.\u{201D}")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                model.cancelDraftCompose()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)

            GenerateButton(disabled: !model.hasSelection || isGenerateBlocked, action: { model.generateDraft() })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.bgSunken)
    }

    private var isGenerateBlocked: Bool {
        // Custom preset needs at least a hint of instruction so the model
        // has something concrete to act on; the preset rubric is empty.
        model.draftPreset == .custom &&
            model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct GenerateButton: View {
    let disabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Generate")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(disabled ? Palette.textFaint : Palette.bg)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(buttonFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private var buttonFill: Color {
        if disabled { return Palette.surface }
        return isHovering ? Color.white : Palette.accent
    }
}

private struct PresetTile: View {
    let preset: CitedClipDraftPreset
    let isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: preset.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Palette.bg : Palette.textPrimary)
                    Text(preset.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Palette.bg : Palette.textPrimary)
                    Spacer(minLength: 0)
                }
                Text(preset.subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? Palette.bg.opacity(0.7) : Palette.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tileFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tileStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private var tileFill: Color {
        if isSelected { return Palette.accent }
        if isHovering { return Palette.surfaceHover }
        return Palette.surface
    }

    private var tileStroke: Color {
        isSelected ? Palette.accent : Palette.strokeFaint
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceActive)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
    }
}

private struct DraftingView: View {
    @ObservedObject var model: CitedClipboardPopoverModel
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.textPrimary)
                .scaleEffect(1 + 0.04 * sin(phase))
                .opacity(0.75 + 0.25 * (0.5 + 0.5 * sin(phase)))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        phase = .pi
                    }
                }

            VStack(spacing: 4) {
                Text("Drafting…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Composing \(model.draftPreset.displayName.lowercased()) from \(model.draftSources.count) source\(model.draftSources.count == 1 ? "" : "s")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Button {
                model.cancelDraftRun()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
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

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 16)
    }
}

private struct DraftSurfaceView: View {
    @ObservedObject var model: CitedClipboardPopoverModel
    var onCopyAndClose: () -> Void

    @State private var regenerateHover = false
    @State private var discardHover = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.draftOutput)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Palette.bgRaised)

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Motion.springSnap) { model.discardDraft() }
            } label: {
                Text("Discard")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(discardHover ? Palette.surfaceHover : Color.clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(Motion.hoverFade) { discardHover = hovering }
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(Motion.springSnap) { model.regenerateDraft() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Regenerate")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(regenerateHover ? Palette.surfaceHover : Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(Motion.hoverFade) { regenerateHover = hovering }
            }

            CopyDraftButton(action: onCopyAndClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.bgSunken)
    }
}

private struct CopyDraftButton: View {
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Copy")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Palette.bg)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Color.white : Palette.accent)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help("Copy draft as markdown")
    }
}
