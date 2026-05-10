import SwiftUI

/// Inline AI answer card surfaced above search results when the query reads
/// as a question. Matches the flat monochrome plate aesthetic of the rest
/// of the browser: solid `bgRaised` fill, 1px hairline border, no shadow,
/// 10px corner radius — same `Metrics.webviewRadius` as the search panel.
struct AIAnswerView: View {
    enum Phase: Equatable {
        case loading
        case loaded(String)
        case failed(String)
    }

    let phase: Phase
    let citationURLs: [URL]
    let citationTitles: [String]
    let providerName: String
    let modelName: String
    var onOpenSource: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            divider
            content
            if case .loaded(let text) = phase {
                sourcesFooter(for: text)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            SparkleMark(isPulsing: isLoading)

            Text("Answer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 8)

            if !badgeLabel.isEmpty {
                Text(badgeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
        }
    }

    /// Compact, lowercase model badge. Collapses redundant "claude · claude
    /// haiku 4.5" to just "claude haiku 4.5" when the model name already
    /// begins with the provider brand — keeps the chrome quiet.
    private var badgeLabel: String {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let provider = providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model.isEmpty { return provider }
        if provider.isEmpty { return model }
        if model.hasPrefix(provider) { return model }
        return "\(provider) · \(model)"
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            AIAnswerShimmer()
                .transition(.opacity)
        case .loaded(let text):
            MarkdownView(text: text, citations: citationURLs)
                .transition(.opacity.combined(with: .offset(y: 4)))
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
            }
            .foregroundStyle(Palette.textMuted)
        }
    }

    // MARK: - Source footer

    @ViewBuilder
    private func sourcesFooter(for text: String) -> some View {
        let cited = Self.citedIndices(in: text, max: citationURLs.count)
        if !cited.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                divider
                Text("SOURCES")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.textFaint)

                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(cited, id: \.self) { index in
                        SourcePill(
                            index: index,
                            url: citationURLs[index - 1],
                            title: index <= citationTitles.count ? citationTitles[index - 1] : citationURLs[index - 1].host(percentEncoded: false) ?? "",
                            onOpen: { onOpenSource(citationURLs[index - 1]) }
                        )
                    }
                }
            }
        }
    }

    static func citedIndices(in text: String, max upperBound: Int) -> [Int] {
        guard upperBound > 0 else { return [] }
        let pattern = #"\[(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var seen = Set<Int>()
        var ordered: [Int] = []
        for match in matches {
            guard let r = Range(match.range(at: 1), in: text),
                  let n = Int(text[r]),
                  n >= 1, n <= upperBound,
                  !seen.contains(n) else { continue }
            seen.insert(n)
            ordered.append(n)
        }
        return ordered
    }
}

// MARK: - Sparkle mark

/// Flat sparkles glyph used in the answer header. Pulses opacity while the
/// model is generating — no glow, no circular plate, no shadow, so it
/// matches the inline icons used elsewhere (e.g. SearchResultsView header).
private struct SparkleMark: View {
    var isPulsing: Bool
    @State private var pulse = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
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
                    withAnimation(.easeOut(duration: 0.2)) {
                        pulse = false
                    }
                }
            }
    }
}

// MARK: - Shimmer loading

private struct AIAnswerShimmer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShimmerBar(widthFraction: 1.00, delay: 0.00)
            ShimmerBar(widthFraction: 1.00, delay: 0.06)
            ShimmerBar(widthFraction: 0.86, delay: 0.12)
            ShimmerBar(widthFraction: 0.94, delay: 0.18)
            ShimmerBar(widthFraction: 0.55, delay: 0.24)
        }
    }
}

private struct ShimmerBar: View {
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
                                .init(color: Color.white.opacity(0.13), location: clamp(phase)),
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

    private func clamp(_ v: CGFloat) -> CGFloat {
        max(0, min(1, v))
    }
}

// MARK: - Source pill

/// A clickable citation pill in the footer. Mirrors the inline `[N]` chip
/// rendered inside the markdown body — same white 10% bracket background,
/// same 9.5px monospaced index — so the footer reads as a continuation of
/// the references in the text.
private struct SourcePill: View {
    let index: Int
    let url: URL
    let title: String
    var onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Text("[\(index)]")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .kerning(0.4)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    }

                if let host = url.host(percentEncoded: false) {
                    FaviconView(host: host)
                        .frame(width: 12, height: 12)
                }

                Text(displayLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(url.absoluteString)
    }

    private var displayLabel: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }
}

// MARK: - Flow layout

/// Wraps children onto multiple lines like CSS flex-wrap. Used for the
/// citation source pill row so long titles flow gracefully.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            if rowWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += needed
            }
        }

        let totalHeight = rows
            .map { $0.map(\.height).max() ?? 0 }
            .reduce(0) { $0 + $1 } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: maxWidth.isFinite ? maxWidth : 0, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
