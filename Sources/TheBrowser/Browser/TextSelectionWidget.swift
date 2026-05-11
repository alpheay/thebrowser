import AppKit
import SwiftUI

// MARK: - View model

/// Owns the lifecycle of the highlight widget. A live ``TextSelectionInfo``
/// (provided by the active tab while the user has text selected) anchors the
/// floating Summarize/Ask pill above the highlight. Once the user fires
/// either action, the widget captures the selected text into a session that
/// persists even if the user clicks away and the page selection collapses —
/// so the resulting summary or chat hand-off doesn't lose its context.
@MainActor
final class TextSelectionWidgetModel: ObservableObject {
    enum SummaryState: Equatable {
        case loading
        case success(String)
        case failed(String)
    }

    struct SummarySession: Identifiable, Equatable {
        let id = UUID()
        var sourceText: String
        var anchor: CGRect
        var state: SummaryState
    }

    @Published var summary: SummarySession?

    private var summaryTask: Task<Void, Never>?

    /// Captures the highlight into a Summarize session and kicks off the
    /// CLI call. Anchor rect is the live selection rect at click time so the
    /// summary card lands near the user's cursor.
    func summarize(text: String, anchor: CGRect, pageContext: BrowserPageContext) {
        summaryTask?.cancel()
        let session = SummarySession(sourceText: text, anchor: anchor, state: .loading)
        summary = session

        summaryTask = Task { @MainActor [weak self] in
            do {
                let response = try await TextSelectionSummarizer.summarize(
                    text: text,
                    pageContext: pageContext
                )
                guard let self, !Task.isCancelled, self.summary?.id == session.id else { return }
                self.summary?.state = .success(response)
            } catch {
                guard let self, !Task.isCancelled, self.summary?.id == session.id else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.summary?.state = .failed(message)
            }
        }
    }

    func dismissSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summary = nil
    }
}

// MARK: - One-shot summarizer

/// Single-shot summarization client. Mirrors `AIAnswerClient`'s pattern of
/// using the user's selected provider with a task-specific system prompt
/// and the provider's fast model so the result lands quickly.
enum TextSelectionSummarizer {
    static func summarize(text: String, pageContext: BrowserPageContext) async throws -> String {
        let configuration = AIHarnessConfiguration.current()
        let prompt = formatPrompt(text: text, pageContext: pageContext)
        let response = try await AIProviderClient().ask(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            modelOverride: configuration.model.isEmpty ? configuration.provider.fastModelID : nil
        )
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return trimmed
    }

    private static func formatPrompt(text: String, pageContext: BrowserPageContext) -> String {
        var lines: [String] = []
        lines.append("Summarize the highlighted passage below in 2–4 short sentences.")
        lines.append("Lead with the answer; no preamble like \"This passage…\".")
        lines.append("Plain prose only — no headings, no bullets unless the source is clearly a list.")
        lines.append("Preserve specific names, numbers, and dates from the passage.")
        lines.append("")
        if !pageContext.title.isEmpty || !pageContext.url.isEmpty {
            lines.append("Source page:")
            if !pageContext.title.isEmpty { lines.append("Title: \(pageContext.title)") }
            if !pageContext.url.isEmpty { lines.append("URL: \(pageContext.url)") }
            lines.append("")
        }
        lines.append("Highlighted passage:")
        lines.append("\"\"\"")
        lines.append(text)
        lines.append("\"\"\"")
        return lines.joined(separator: "\n")
    }

    private static let systemPrompt = """
    You are a concise summarizer. Always reply with a short, plain-prose summary of the passage the user highlights. Do not add commentary, follow-up questions, or formatting outside what was requested.
    """
}

// MARK: - Overlay container

/// Floating Summarize/Ask pill plus the Summary card, layered on top of the
/// active tab's web content. Observes the tab directly so changes to its
/// ``selectionInfo`` re-render the overlay (the parent shell reaches the tab
/// through a computed property and can't subscribe to its publishers).
struct TextSelectionOverlay: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var widgetModel: TextSelectionWidgetModel
    var pageContext: BrowserPageContext
    var onAsk: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Transparent backdrop sized to the webview so positioned
                // widgets resolve their `.position(_:)` against the full
                // overlay frame. Hit testing is off so clicks on empty
                // space fall through to the webview.
                Color.clear
                    .allowsHitTesting(false)

                if let summary = widgetModel.summary {
                    let position = summaryPosition(for: summary.anchor, in: geo.size)
                    TextSelectionSummaryCard(
                        session: summary,
                        onClose: {
                            withAnimation(Motion.springSnap) {
                                widgetModel.dismissSummary()
                            }
                        },
                        onAsk: {
                            let text = summary.sourceText
                            withAnimation(Motion.springSnap) {
                                widgetModel.dismissSummary()
                            }
                            onAsk(text)
                        },
                        onCopy: {
                            if case .success(let text) = summary.state {
                                copyToPasteboard(text)
                            }
                        }
                    )
                    .position(position)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                    .id(summary.id)
                } else if let info = tab.selectionInfo {
                    let position = widgetPosition(for: info.rect, in: geo.size)
                    TextSelectionWidget(
                        onSummarize: {
                            // Snapshot the highlight, then drop the live
                            // selection echo so the pill doesn't try to
                            // reappear behind the summary card.
                            let captured = info
                            tab.clearSelectionInfo()
                            withAnimation(Motion.springSnap) {
                                widgetModel.summarize(
                                    text: captured.text,
                                    anchor: captured.rect,
                                    pageContext: pageContext
                                )
                            }
                        },
                        onAsk: {
                            let text = info.text
                            tab.clearSelectionInfo()
                            onAsk(text)
                        }
                    )
                    .position(position)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Motion.springSnap, value: widgetModel.summary?.id)
            .animation(Motion.springSnap, value: tab.selectionInfo)
        }
    }

    /// Centers the action pill horizontally on the highlight and floats it
    /// just above. Falls back to below the highlight if there isn't
    /// headroom for the pill to clear the webview's top edge.
    private func widgetPosition(for rect: CGRect, in container: CGSize) -> CGPoint {
        let approxWidth: CGFloat = 200
        let approxHeight: CGFloat = 34
        let halfW = approxWidth / 2
        let halfH = approxHeight / 2

        let centerX = min(max(halfW + 6, rect.midX), container.width - halfW - 6)
        let aboveY = rect.minY - halfH - 8
        let belowY = rect.maxY + halfH + 8
        let preferAbove = aboveY >= halfH + 6
        let y = preferAbove ? aboveY : belowY
        let clampedY = min(max(halfH + 6, y), container.height - halfH - 6)
        return CGPoint(x: centerX, y: clampedY)
    }

    /// Picks a center point for the summary card that stays out of the way
    /// of the highlight and surrounding reading context. The algorithm
    /// tries placements in this order:
    ///
    /// 1. Right of the highlight (if there's room for the full card width
    ///    and the card fits vertically) — the most common winner for body
    ///    text inside a centered article column.
    /// 2. Left of the highlight — same idea for selections that sit close
    ///    to the right edge of the page.
    /// 3. Below the highlight (if there's more space below than above).
    /// 4. Above the highlight.
    ///
    /// Card width is fixed at 360pt; height assumes the worst case (~360pt
    /// for a full success card with header, body, and footer). Real cards
    /// are often shorter — the over-estimate just leaves a bit more breathing
    /// room around the card, which is fine.
    private func summaryPosition(for rect: CGRect, in container: CGSize) -> CGPoint {
        let cardW: CGFloat = 360
        let cardH: CGFloat = 360
        let gap: CGFloat = 14
        let margin: CGFloat = 12
        let halfW = cardW / 2
        let halfH = cardH / 2

        // Free space outside the highlight rect, minus the gap we want
        // between the highlight and the card.
        let above = rect.minY - gap
        let below = container.height - rect.maxY - gap
        let left = rect.minX - gap
        let right = container.width - rect.maxX - gap

        // Vertical center bounded so the card stays inside the viewport,
        // used for both side placements.
        let clampedMidY = max(margin + halfH, min(rect.midY, container.height - margin - halfH))
        let clampedMidX = max(margin + halfW, min(rect.midX, container.width - margin - halfW))

        // Side placement requires enough horizontal room AND that the card
        // itself fits vertically inside the viewport.
        let fitsVertical = container.height >= cardH + 2 * margin

        if fitsVertical && right >= cardW + margin {
            return CGPoint(x: rect.maxX + gap + halfW, y: clampedMidY)
        }
        if fitsVertical && left >= cardW + margin {
            return CGPoint(x: rect.minX - gap - halfW, y: clampedMidY)
        }

        // Falling back to above/below — pick the direction with more space
        // so the card overlaps the selection as little as possible.
        if below >= above {
            let y = rect.maxY + gap + halfH
            let clampedY = max(margin + halfH, min(y, container.height - margin - halfH))
            return CGPoint(x: clampedMidX, y: clampedY)
        } else {
            let y = rect.minY - gap - halfH
            let clampedY = max(margin + halfH, min(y, container.height - margin - halfH))
            return CGPoint(x: clampedMidX, y: clampedY)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Floating action pill (Summarize / Ask)

struct TextSelectionWidget: View {
    var onSummarize: () -> Void
    var onAsk: () -> Void

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            WidgetActionButton(
                icon: "text.alignleft",
                label: "Summarize",
                action: onSummarize
            )
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1, height: 18)
            WidgetActionButton(
                icon: "questionmark.bubble",
                label: "Ask",
                action: onAsk
            )
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
        .shadow(color: Color.black.opacity(0.28), radius: 4, x: 0, y: 2)
        .scaleEffect(appeared ? 1 : 0.86)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

private struct WidgetActionButton: View {
    let icon: String
    let label: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Palette.text : Palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }
}

// MARK: - Summary card

struct TextSelectionSummaryCard: View {
    let session: TextSelectionWidgetModel.SummarySession
    var onClose: () -> Void
    var onAsk: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.stroke).frame(height: 1)
            content
            if case .success = session.state {
                Rectangle().fill(Palette.stroke).frame(height: 1)
                footer
            }
        }
        .frame(width: 360)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.32), radius: 6, x: 0, y: 3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SummarySparkle(isPulsing: session.state == .loading)
            Text("Summary")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 22, height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                SummaryShimmerBar(widthFraction: 1.00, delay: 0.00)
                SummaryShimmerBar(widthFraction: 0.94, delay: 0.06)
                SummaryShimmerBar(widthFraction: 0.78, delay: 0.12)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)

        case .success(let text):
            ScrollView {
                MarkdownView(text: text)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 280)
            .transition(.opacity)

        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterPillButton(icon: "doc.on.doc", label: "Copy", action: onCopy)
            FooterPillButton(icon: "questionmark.bubble", label: "Ask follow-up", action: onAsk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct SummarySparkle: View {
    var isPulsing: Bool
    @State private var pulse = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .opacity(isPulsing && pulse ? 0.42 : 1.0)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: isPulsing) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pulse = false }
                }
            }
    }
}

private struct SummaryShimmerBar: View {
    var widthFraction: CGFloat
    var delay: Double
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * widthFraction
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.30)),
                                .init(color: Color.white.opacity(0.13), location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.30))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .frame(width: w, height: 11, alignment: .leading)
        }
        .frame(height: 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.35
                }
            }
        }
    }
}

private struct FooterPillButton: View {
    let icon: String
    let label: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }
}
