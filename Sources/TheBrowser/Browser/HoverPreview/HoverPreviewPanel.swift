import SwiftUI

/// Actions the panel surfaces in its footer. The host wires these to the
/// browser model — the panel itself is purely presentational.
struct HoverPreviewActions {
    var openInTab: () -> Void
    var openInBackground: () -> Void
    var pin: () -> Void
}

/// Floating overlay that hosts the hover preview panel. Layered into the
/// browser shell next to ``TextSelectionOverlay`` and consumes the same
/// viewport CSS-pixel coordinate space.
struct HoverPreviewOverlay: View {
    @ObservedObject var model: HoverPreviewModel
    var actions: HoverPreviewActions

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)

                if let session = model.session {
                    let position = panelPosition(for: session.anchor, in: geo.size)
                    HoverPreviewPanel(
                        session: session,
                        actions: actions,
                        onHoverChange: { model.setPanelHovered($0) }
                    )
                    .position(position)
                    .transition(.opacity)
                    .id(session.tabID)
                }
            }
            .animation(.easeOut(duration: 0.14), value: model.session?.id)
        }
    }

    /// Pick a center point for the panel that stays out of the way of the
    /// link. Tries below-right, below-left, above-right, above-left,
    /// clamped to the viewport. Same flavor as
    /// ``TextSelectionOverlay.summaryPosition`` but simpler — the panel
    /// is wider so we mostly land below/above.
    private func panelPosition(for rect: CGRect, in container: CGSize) -> CGPoint {
        let panelW = HoverPreviewPanel.panelWidth
        let panelH = HoverPreviewPanel.panelHeight
        let gap: CGFloat = 12
        let margin: CGFloat = 10
        let halfW = panelW / 2
        let halfH = panelH / 2

        let above = rect.minY - gap
        let below = container.height - rect.maxY - gap

        // Prefer below if there's room; otherwise above. If both are tight,
        // pick whichever has more space.
        let placeBelow: Bool
        if below >= panelH + margin { placeBelow = true }
        else if above >= panelH + margin { placeBelow = false }
        else { placeBelow = below >= above }

        let centerY: CGFloat
        if placeBelow {
            centerY = min(rect.maxY + gap + halfH, container.height - margin - halfH)
        } else {
            centerY = max(rect.minY - gap - halfH, margin + halfH)
        }

        // Horizontally center on the link but keep the panel fully visible.
        let centerX = min(
            max(margin + halfW, rect.midX),
            max(margin + halfW, container.width - margin - halfW)
        )
        return CGPoint(x: centerX, y: centerY)
    }
}

/// The 480×360 hover preview panel. Header (favicon + title + URL), AI
/// one-line summary, scrollable body, footer (Open / Open in background /
/// Pin). Visual chrome matches ``SmartReadCard``.
struct HoverPreviewPanel: View {
    static let panelWidth: CGFloat = 480
    static let panelHeight: CGFloat = 360

    let session: HoverPreviewModel.PeekSession
    let actions: HoverPreviewActions
    var onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            summaryRow
            divider
            bodyArea
            divider
            footer
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
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
        .onHover { onHoverChange($0) }
    }

    private var divider: some View {
        Rectangle().fill(Palette.stroke).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HoverPreviewFavicon(faviconURL: faviconURL, host: hostString)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(displayURL)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: AI summary

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, 1)
                .modifier(HoverPreviewSparkPulse(active: summaryIsLoading))

            summaryContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summaryContent: some View {
        switch session.summary {
        case .idle, .loading:
            HoverPreviewShimmerBar(widthFraction: 0.82)
                .frame(height: 11)
        case .ready(let text):
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .transition(.opacity)
        case .failed:
            Text("Couldn't summarize this page.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyArea: some View {
        switch session.content {
        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                HoverPreviewShimmerBar(widthFraction: 1.0)
                HoverPreviewShimmerBar(widthFraction: 0.92)
                HoverPreviewShimmerBar(widthFraction: 0.68)
                HoverPreviewShimmerBar(widthFraction: 0.84)
                HoverPreviewShimmerBar(widthFraction: 0.5)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .ready(let content):
            ScrollView {
                Text(content.bodyText.isEmpty ? content.description : content.bodyText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .authRequired:
            HoverPreviewPlaceholder(
                icon: "lock.fill",
                title: "Sign-in required",
                message: "This page needs you to be signed in. Open it in a tab to view."
            )

        case .unavailable(let reason):
            HoverPreviewPlaceholder(
                icon: "exclamationmark.triangle",
                title: "Preview unavailable",
                message: reason
            )
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            HoverPreviewFooterButton(
                icon: "arrow.up.right.square",
                label: "Open",
                hint: "⏎",
                action: actions.openInTab
            )
            HoverPreviewFooterButton(
                icon: "rectangle.stack.badge.plus",
                label: "Background",
                hint: "⌘⏎",
                action: actions.openInBackground
            )
            HoverPreviewFooterButton(
                icon: "pin",
                label: "Pin",
                hint: nil,
                action: actions.pin
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Derived

    private var summaryIsLoading: Bool {
        switch session.summary {
        case .idle, .loading: return true
        default: return false
        }
    }

    private var displayTitle: String {
        switch session.content {
        case .ready(let content):
            let t = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        default: break
        }
        if !session.fallbackTitle.isEmpty { return session.fallbackTitle }
        return session.url.host(percentEncoded: false) ?? session.url.absoluteString
    }

    private var displayURL: String {
        let final: URL
        switch session.content {
        case .ready(let content): final = content.finalURL
        default: final = session.url
        }
        return final.absoluteString
    }

    private var hostString: String {
        switch session.content {
        case .ready(let content):
            return content.finalURL.host(percentEncoded: false) ?? ""
        default:
            return session.url.host(percentEncoded: false) ?? ""
        }
    }

    private var faviconURL: URL? {
        if case .ready(let content) = session.content { return content.faviconURL }
        return nil
    }
}

// MARK: - Pieces

private struct HoverPreviewFavicon: View {
    let faviconURL: URL?
    let host: String

    var body: some View {
        Group {
            if let faviconURL {
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    default:
                        fallback
                    }
                }
            } else if !host.isEmpty {
                FaviconView(host: host)
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        Image(systemName: "globe")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.textMuted)
    }
}

private struct HoverPreviewFooterButton: View {
    let icon: String
    let label: String
    var hint: String?
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                if let hint {
                    Text(hint)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
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

private struct HoverPreviewPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HoverPreviewShimmerBar: View {
    var widthFraction: CGFloat
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * widthFraction
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.3)),
                                .init(color: Color.white.opacity(0.16), location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.3))
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
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.3
            }
        }
    }
}

private struct HoverPreviewSparkPulse: ViewModifier {
    var active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(active && pulse ? 0.45 : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: active) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.16)) { pulse = false }
                }
            }
    }
}
