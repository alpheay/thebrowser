import AppKit
import SwiftUI

/// The instant-recall command bar — a Spotlight-flavoured overlay that answers
/// "where did I read that" from the local index. Everything it shows comes
/// from on-device retrieval; in local-answer mode it also stitches a cited
/// answer on-device. Nothing here touches the network or a cloud model.
@MainActor
struct RecallPanelView: View {
    @ObservedObject var model: RecallPanelModel
    let onOpen: (URL) -> Void
    let onOpenInBackground: (URL) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            panel
                .frame(maxWidth: 640)
                .padding(.top, 92)
                .padding(.horizontal, 24)
        }
        .background {
            RecallKeyMonitor(
                onUp: { model.moveSelection(-1) },
                onDown: { model.moveSelection(1) },
                onReturn: { openSelected(background: false) },
                onCommandReturn: { openSelected(background: true) },
                onEscape: onClose
            )
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchField

            if model.answer != nil || model.isAnswering {
                separator
                answerSection
            }

            if model.didSearch || model.isSearching {
                separator
                resultsSection
            } else {
                separator
                idleHint
            }

            footer
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x161616))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 40, y: 18)
    }

    private var separator: some View {
        Rectangle().fill(Palette.strokeFaint).frame(height: 1)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(searchFocused ? Palette.textPrimary : Palette.textMuted)
            TextField("Ask your history…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
                .onChange(of: model.query) { _, _ in model.onQueryChange() }
                .onSubmit { openSelected(background: false) }
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.textMuted)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    // MARK: - Answer (local, zero-egress)

    @ViewBuilder
    private var answerSection: some View {
        if let answer = model.answer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("ANSWERED ON THIS MAC")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.4)
                }
                .foregroundStyle(Palette.textFaint)

                Text(answer.summary)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if !answer.citations.isEmpty {
                    FlowChips(citations: answer.citations, onOpen: onOpen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Palette.textMuted)
                Text("Reading your pages…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if model.results.isEmpty {
            if model.isSearching {
                Color.clear.frame(height: 1)
            } else {
                emptyResults
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, hit in
                            RecallResultRow(
                                hit: hit,
                                isSelected: index == model.selectedIndex,
                                onOpen: { onOpen(hit.url); onClose() },
                                onToggleStar: { model.toggleStar(hit) }
                            )
                            .id(hit.id)
                            .onHover { hovering in
                                if hovering { model.selectedIndex = index }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)
                .onChange(of: model.selectedIndex) { _, newValue in
                    guard model.results.indices.contains(newValue) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(model.results[newValue].id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.textMuted)
            Text("Nothing in your history matches")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text("Only pages you spend time reading are indexed — and only on this Mac.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 30)
    }

    private var idleHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find anything you've read")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            ForEach(Self.examples, id: \.self) { example in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                    Text(example)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Palette.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            keyHint("↑↓", "move")
            keyHint("↵", "open")
            keyHint("⌘↵", "background")
            keyHint("esc", "close")
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("on-device")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous
            )
            .fill(Palette.bgSunken.opacity(0.5))
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.strokeFaint).frame(height: 1)
        }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.bgRaised)
                }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
    }

    private func openSelected(background: Bool) {
        guard let hit = model.selectedHit else { return }
        if background {
            onOpenInBackground(hit.url)
        } else {
            onOpen(hit.url)
            onClose()
        }
    }

    private static let examples = [
        "that transformers article I read last week",
        "the pricing page on stripe.com",
        "what was I reading about sqlite yesterday"
    ]
}

// MARK: - Citation chips

private struct FlowChips: View {
    let citations: [RecallCitation]
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(citations) { citation in
                Button {
                    onOpen(citation.url)
                } label: {
                    HStack(spacing: 7) {
                        if let host = citation.url.host(percentEncoded: false) {
                            FaviconView(host: host).frame(width: 13, height: 13)
                        }
                        Text(citation.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.textFaint)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background {
                        Capsule().fill(Palette.surface)
                    }
                    .overlay {
                        Capsule().stroke(Palette.stroke, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Result row

private struct RecallResultRow: View {
    let hit: RecallHit
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggleStar: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                    Text(hit.snippet)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onToggleStar) {
                    Image(systemName: hit.starred ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hit.starred ? Palette.textPrimary : Palette.textFaint)
                }
                .buttonStyle(.plain)
                .help(hit.starred ? "Unstar" : "Star — ranks this higher in recall")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.8) : Color.clear)
                    .frame(width: 2.5, height: 24)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
            if !hit.host.isEmpty {
                FaviconView(host: hit.host).frame(width: 16, height: 16)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if !hit.host.isEmpty { parts.append(hit.host) }
        parts.append(Self.relative.localizedString(for: hit.lastVisitedAt, relativeTo: Date()))
        if hit.visitCount > 1 { parts.append("read \(hit.visitCount)×") }
        return parts.joined(separator: "  ·  ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Key monitor

/// Local key monitor for the recall panel: arrows move the selection, Return
/// opens, ⌘Return opens in the background, Escape closes. Installed only while
/// the panel is on screen, mirroring the History modal's Escape bridge.
private struct RecallKeyMonitor: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onReturn: () -> Void
    let onCommandReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(
            onUp: onUp, onDown: onDown, onReturn: onReturn,
            onCommandReturn: onCommandReturn, onEscape: onEscape
        )
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(
            onUp: onUp, onDown: onDown, onReturn: onReturn,
            onCommandReturn: onCommandReturn, onEscape: onEscape
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(
            onUp: @escaping () -> Void,
            onDown: @escaping () -> Void,
            onReturn: @escaping () -> Void,
            onCommandReturn: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 126: onUp(); return nil
                case 125: onDown(); return nil
                case 36, 76:
                    if event.modifierFlags.contains(.command) { onCommandReturn() } else { onReturn() }
                    return nil
                case 53: onEscape(); return nil
                default: return event
                }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
