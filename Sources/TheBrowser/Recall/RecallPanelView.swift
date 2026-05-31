import AppKit
import SwiftUI

/// The instant-recall command bar — a refined, Spotlight-flavoured overlay that
/// answers "where did I read that" from the local index. Everything it shows
/// comes from on-device retrieval; in local-answer mode it also stitches a
/// cited answer on-device. Nothing here touches the network or a cloud model.
@MainActor
struct RecallPanelView: View {
    @ObservedObject var model: RecallPanelModel
    let currentURL: URL?
    let onOpen: (URL) -> Void
    let onOpenInBackground: (URL) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var appeared = false

    /// Meaningful query words, used to gently emphasize matches in snippets.
    private var highlightTerms: [String] {
        Array(RecallAnswerEngine.keywords(model.query))
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            panel
                .frame(maxWidth: 660)
                .padding(.horizontal, 24)
                .padding(.top, 104)
                .scaleEffect(appeared ? 1 : 0.975, anchor: .top)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -10)
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
            model.loadRelated(to: currentURL)
            withAnimation(Motion.springBloom) { appeared = true }
        }
    }

    private var backdrop: some View {
        Rectangle()
            .fill(Color.black.opacity(0.5))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onClose() }
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
                if !(model.results.isEmpty && model.isSearching) {
                    separator
                }
                resultsSection
            } else {
                separator
                idleState
            }

            footer
        }
        .background(panelMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            // A stroke that's brighter at the top reads as light from above —
            // the quiet "premium glass" cue, still monochrome.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: 50, x: 0, y: 26)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
    }

    private var panelMaterial: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Palette.bgRaised)
    }

    private var separator: some View {
        Rectangle().fill(Palette.strokeFaint).frame(height: 1)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(searchFocused ? Palette.textSecondary : Palette.textMuted)
                .animation(Motion.hoverFade, value: searchFocused)

            TextField("", text: $model.query, prompt: prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
                .onChange(of: model.query) { _, _ in model.onQueryChange() }
                .onSubmit { openSelected(background: false) }

            trailingAccessory
        }
        .padding(.horizontal, 22)
        .frame(height: 60)
    }

    private var prompt: Text {
        Text("Ask your history…").foregroundStyle(Palette.textMuted)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if model.isSearching {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.textMuted)
        } else if !model.query.isEmpty {
            Button { model.query = ""; model.onQueryChange() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textFaint)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Answer (local, zero-egress)

    @ViewBuilder
    private var answerSection: some View {
        if let answer = model.answer {
            VStack(alignment: .leading, spacing: 12) {
                privacyCaption

                Text(answer.summary)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(answer.citations) { citation in
                            CitationChip(citation: citation) { onOpen(citation.url); onClose() }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        } else {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).tint(Palette.textMuted)
                Text("Reading your pages…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }

    private var privacyCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .bold))
            Text("Answered on your Mac")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Palette.textFaint)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if model.results.isEmpty {
            if !model.isSearching { emptyResults }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, hit in
                            RecallResultRow(
                                hit: hit,
                                isSelected: index == model.selectedIndex,
                                highlightTerms: highlightTerms,
                                onOpen: { onOpen(hit.url); onClose() },
                                onToggleStar: { model.toggleStar(hit) }
                            )
                            .id(hit.id)
                            .onHover { if $0 { model.selectedIndex = index } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 408)
                .scrollIndicators(.never)
                .mask(scrollFade)
                .onChange(of: model.selectedIndex) { _, value in
                    guard model.results.indices.contains(value) else { return }
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(model.results[value].id, anchor: .center)
                    }
                }
            }
        }
    }

    /// Soft top/bottom fade so rows dissolve into the chrome rather than
    /// clipping hard against the divider and footer.
    private var scrollFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(Palette.textFaint)
            Text("Nothing in your history matches")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Text("Only pages you actually read are saved — and only on this Mac.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 36)
    }

    // MARK: - Idle state

    @ViewBuilder
    private var idleState: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("RELATED TO THIS PAGE")
                    ForEach(model.related) { doc in
                        SuggestionRow(
                            icon: .favicon(doc.host),
                            text: doc.title.isEmpty ? doc.host : doc.title,
                            trailing: "arrow.up.right"
                        ) { onOpen(doc.url); onClose() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(model.related.isEmpty ? "TRY ASKING" : "OR ASK")
                ForEach(Self.examples, id: \.self) { example in
                    SuggestionRow(icon: .glyph("text.magnifyingglass"), text: example, trailing: nil) {
                        model.query = example
                        model.onQueryChange()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 10, weight: .semibold))
                Text("Private · on-device").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Palette.textFaint)

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                hintKey("↑↓", "move")
                hintKey("↵", "open")
                hintKey("esc", "close")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Palette.bgSunken.opacity(0.6))
        .hairline(.top)
    }

    private func hintKey(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textMuted)
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: - Actions

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

// MARK: - Result row

private struct RecallResultRow: View {
    let hit: RecallHit
    let isSelected: Bool
    let highlightTerms: [String]
    let onOpen: () -> Void
    let onToggleStar: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 13) {
                FaviconTile(host: hit.host)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(hit.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if isSelected || hit.starred {
                            Button(action: onToggleStar) {
                                Image(systemName: hit.starred ? "star.fill" : "star")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(hit.starred ? Palette.textSecondary : Palette.textFaint)
                            }
                            .buttonStyle(.plain)
                            .help(hit.starred ? "Unstar" : "Star — ranks this higher")
                        }
                    }

                    Text(metaLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)

                    Text(highlightedSnippet)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.05) : Color.clear)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.strokeFaint, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hoverFade, value: isSelected)
    }

    private var metaLine: String {
        var parts: [String] = []
        if !hit.host.isEmpty { parts.append(hit.host) }
        parts.append(Self.relative.localizedString(for: hit.lastVisitedAt, relativeTo: Date()))
        if hit.visitCount > 1 { parts.append("read \(hit.visitCount)×") }
        return parts.joined(separator: "  ·  ")
    }

    /// Brightens query words inside the snippet so the match is obvious.
    private var highlightedSnippet: AttributedString {
        var attributed = AttributedString(hit.snippet)
        attributed.foregroundColor = Palette.textMuted
        for term in highlightTerms where term.count >= 3 {
            var cursor = hit.snippet.startIndex
            while let range = hit.snippet.range(
                of: term, options: .caseInsensitive, range: cursor..<hit.snippet.endIndex
            ) {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].foregroundColor = Palette.textSecondary
                    attributed[attrRange].font = .system(size: 12, weight: .semibold)
                }
                cursor = range.upperBound
            }
        }
        return attributed
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Shared pieces

/// A favicon (or fallback glyph) seated in a soft rounded tile.
private struct FaviconTile: View {
    let host: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
            if !host.isEmpty {
                FaviconView(host: host).frame(width: 16, height: 16)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(width: 30, height: 30)
    }
}

private struct CitationChip: View {
    let citation: RecallCitation
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let host = citation.url.host(percentEncoded: false), !host.isEmpty {
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
                Capsule().fill(hovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay { Capsule().strokeBorder(Palette.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hoverFade, value: hovering)
    }
}

/// A quiet, tappable row for the idle state — related pages and example
/// prompts share the look.
private struct SuggestionRow: View {
    enum Icon { case favicon(String); case glyph(String) }

    let icon: Icon
    let text: String
    let trailing: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView
                    .frame(width: 16, height: 16)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovering ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.04) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hoverFade, value: hovering)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .favicon(let host):
            if host.isEmpty {
                Image(systemName: "globe").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textMuted)
            } else {
                FaviconView(host: host)
            }
        case .glyph(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }
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
