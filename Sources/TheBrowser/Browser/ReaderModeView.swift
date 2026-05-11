import AppKit
import Foundation
import SwiftUI

// MARK: - Model

struct ReaderArticle: Equatable {
    var title: String
    var byline: String?
    var siteName: String?
    var readTimeMinutes: Int
    var wordCount: Int
    var blocks: [ReaderBlock]
}

enum ReaderBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case image(url: URL, alt: String, caption: String?)
    case blockquote(String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(String)
    case horizontalRule
}

@MainActor
final class ReaderModeModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(title: String)
        case loaded(ReaderArticle)
        case failed(String)
    }

    enum FontScale: Int, CaseIterable {
        case small = 0
        case medium = 1
        case large = 2
        case xlarge = 3

        var bodySize: CGFloat {
            switch self {
            case .small: return 16
            case .medium: return 18
            case .large: return 20
            case .xlarge: return 22
            }
        }

        func bigger() -> FontScale { Self(rawValue: min(rawValue + 1, FontScale.xlarge.rawValue)) ?? self }
        func smaller() -> FontScale { Self(rawValue: max(rawValue - 1, FontScale.small.rawValue)) ?? self }
    }

    @Published var isPresented = false
    @Published var phase: Phase = .idle
    @Published var fontScale: FontScale = .medium

    private var task: Task<Void, Never>?

    func toggle(tab: BrowserTab) {
        if isPresented {
            close()
        } else {
            start(tab: tab)
        }
    }

    func start(tab: BrowserTab) {
        guard tab.isSmartReadEligible else { return }

        task?.cancel()
        isPresented = true
        phase = .loading(title: tab.displayTitle)

        task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            let article = await tab.extractReaderArticle()
            guard !Task.isCancelled else { return }
            if let article {
                self.phase = .loaded(article)
            } else {
                self.phase = .failed("Reader Mode isn't available for this page.")
            }
        }
    }

    func close() {
        task?.cancel()
        task = nil
        withAnimation(Motion.springSnap) {
            isPresented = false
            phase = .idle
        }
    }
}

// MARK: - View

struct ReaderModeView: View {
    @ObservedObject var model: ReaderModeModel
    var onOpenLink: (URL) -> Void = { url in NSWorkspace.shared.open(url) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card

            ReaderControls(
                scale: $model.fontScale,
                onClose: { model.close() }
            )
            .padding(.top, 14)
            .padding(.trailing, Metrics.webviewInset + 12)
        }
        .background(
            EscapeKeyCatcher { model.close() }
        )
        .environment(\.openURL, OpenURLAction { url in
            onOpenLink(url)
            return .handled
        })
    }

    private var card: some View {
        ZStack {
            ReaderTheme.surface
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Metrics.webviewInset)
        .padding(.bottom, Metrics.webviewInset)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .loading(let title):
            ReaderLoadingView(title: title)
                .transition(.opacity)
        case .loaded(let article):
            ReaderArticleScrollView(article: article, scale: model.fontScale)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                ))
        case .failed(let message):
            ReaderFailedView(message: message, onClose: { model.close() })
                .transition(.opacity)
        }
    }
}

// MARK: - Article rendering

private struct ReaderArticleScrollView: View {
    let article: ReaderArticle
    let scale: ReaderModeModel.FontScale

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReaderHeader(article: article, scale: scale)
                VStack(alignment: .leading, spacing: ReaderTheme.blockSpacing) {
                    ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                        ReaderBlockView(block: block, scale: scale)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ReaderTheme.cardHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .frame(maxWidth: ReaderTheme.cardMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ReaderHeader: View {
    let article: ReaderArticle
    let scale: ReaderModeModel.FontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                if let site = article.siteName, !site.isEmpty {
                    Text(site.uppercased())
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(ReaderTheme.textMuted)
                    Circle()
                        .fill(ReaderTheme.textMuted.opacity(0.4))
                        .frame(width: 3, height: 3)
                }
                Text("\(article.readTimeMinutes) MIN READ")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(ReaderTheme.textMuted)
            }

            Text(article.title)
                .font(.system(size: titleSize, weight: .semibold, design: .serif))
                .foregroundStyle(ReaderTheme.textPrimary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let byline = article.byline, !byline.isEmpty {
                HStack(spacing: 8) {
                    Text("BY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(ReaderTheme.textMuted)
                    Text(byline)
                        .font(.system(size: 14, weight: .medium, design: .serif))
                        .italic()
                        .foregroundStyle(ReaderTheme.textSecondary)
                }
            }

            Rectangle()
                .fill(ReaderTheme.hairline)
                .frame(height: 1)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ReaderTheme.cardHorizontalPadding)
        .padding(.top, 96)
        .padding(.bottom, 28)
    }

    private var titleSize: CGFloat {
        switch scale {
        case .small: return 30
        case .medium: return 34
        case .large: return 38
        case .xlarge: return 42
        }
    }
}

private struct ReaderBlockView: View {
    let block: ReaderBlock
    let scale: ReaderModeModel.FontScale

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level: level), weight: .semibold, design: .serif))
                .foregroundStyle(ReaderTheme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 18 : 8)
                .padding(.bottom, 2)
        case .paragraph(let text):
            ReaderInlineText(text: text, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let url, let alt, let caption):
            ReaderImage(url: url, alt: alt, caption: caption)
        case .blockquote(let text):
            ReaderBlockquote(text: text, scale: scale)
        case .unorderedList(let items):
            ReaderList(items: items, ordered: false, scale: scale)
        case .orderedList(let items):
            ReaderList(items: items, ordered: true, scale: scale)
        case .codeBlock(let code):
            ReaderCodeBlock(code: code)
        case .horizontalRule:
            Rectangle()
                .fill(ReaderTheme.hairline)
                .frame(height: 1)
                .padding(.vertical, 12)
        }
    }

    private func headingSize(level: Int) -> CGFloat {
        let base: CGFloat
        switch level {
        case 1: base = 28
        case 2: base = 24
        case 3: base = 20
        case 4: base = 18
        default: base = 16
        }
        switch scale {
        case .small: return base - 2
        case .medium: return base
        case .large: return base + 2
        case .xlarge: return base + 4
        }
    }
}

private struct ReaderInlineText: View {
    let text: String
    let scale: ReaderModeModel.FontScale

    var body: some View {
        Text(formatted)
            .lineSpacing(scale.bodySize * 0.55)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var formatted: AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            var raw = AttributedString(text)
            raw.font = .system(size: scale.bodySize, weight: .regular, design: .serif)
            raw.foregroundColor = ReaderTheme.textPrimary
            return raw
        }

        attributed.font = .system(size: scale.bodySize, weight: .regular, design: .serif)
        attributed.foregroundColor = ReaderTheme.textPrimary

        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributed[run.range].font = .system(size: scale.bodySize - 1, weight: .medium, design: .monospaced)
                    attributed[run.range].backgroundColor = ReaderTheme.codeInline
                    attributed[run.range].foregroundColor = ReaderTheme.textPrimary
                }
                if intent.contains(.stronglyEmphasized) {
                    attributed[run.range].font = .system(size: scale.bodySize, weight: .bold, design: .serif)
                }
                if intent.contains(.emphasized) {
                    attributed[run.range].font = .system(size: scale.bodySize, weight: .regular, design: .serif).italic()
                }
            }
            if run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = ReaderTheme.textPrimary
            }
        }

        return attributed
    }
}

private struct ReaderImage: View {
    let url: URL
    let alt: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ReaderTheme.imagePlaceholder)
                        .frame(height: 200)
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .failure:
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12.5, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(ReaderTheme.textMuted)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ReaderBlockquote: View {
    let text: String
    let scale: ReaderModeModel.FontScale

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Rectangle()
                .fill(ReaderTheme.quoteBar)
                .frame(width: 2)
            Text(text)
                .font(.system(size: scale.bodySize + 1, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(ReaderTheme.textSecondary)
                .lineSpacing(scale.bodySize * 0.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReaderList: View {
    let items: [String]
    let ordered: Bool
    let scale: ReaderModeModel.FontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: scale.bodySize - 1, weight: ordered ? .medium : .bold, design: .serif))
                        .foregroundStyle(ReaderTheme.textMuted)
                        .frame(width: 22, alignment: .trailing)
                    ReaderInlineText(text: item, scale: scale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ReaderCodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(ReaderTheme.textPrimary)
                .textSelection(.enabled)
                .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ReaderTheme.codeBlock)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ReaderTheme.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Loading & failure states

private struct ReaderLoadingView: View {
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("READING")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(ReaderTheme.textMuted)

                Text(title)
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(ReaderTheme.textPrimary)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(ReaderTheme.hairline)
                    .frame(height: 1)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    ReaderShimmerBar(widthFraction: 1.0, delay: 0.00)
                    ReaderShimmerBar(widthFraction: 0.95, delay: 0.06)
                    ReaderShimmerBar(widthFraction: 0.78, delay: 0.12)
                    ReaderShimmerBar(widthFraction: 0.90, delay: 0.18)
                    ReaderShimmerBar(widthFraction: 0.66, delay: 0.24)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, ReaderTheme.cardHorizontalPadding)
            .padding(.top, 96)
            .padding(.bottom, 72)
            .frame(maxWidth: ReaderTheme.cardMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ReaderShimmerBar: View {
    var widthFraction: CGFloat
    var delay: Double
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * widthFraction
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.3)),
                                .init(color: Color.white.opacity(0.22), location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.3))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .frame(width: width, height: 12, alignment: .leading)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
        }
    }
}

private struct ReaderFailedView: View {
    let message: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Palette.surface)
                Circle()
                    .stroke(ReaderTheme.hairline, lineWidth: 1)
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ReaderTheme.textMuted)
            }
            .frame(width: 56, height: 56)

            Text("Reader Mode unavailable")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(ReaderTheme.textPrimary)

            Text(message)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .foregroundStyle(ReaderTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 320)

            Button(action: onClose) {
                Text("Done")
            }
            .buttonStyle(PillButtonStyle())
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Controls (floating)

private struct ReaderControls: View {
    @Binding var scale: ReaderModeModel.FontScale
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ReaderControlButton(
                icon: "textformat.size.smaller",
                help: "Smaller text"
            ) {
                withAnimation(Motion.springSnap) { scale = scale.smaller() }
            }
            .disabled(scale == .small)

            ReaderControlButton(
                icon: "textformat.size.larger",
                help: "Larger text"
            ) {
                withAnimation(Motion.springSnap) { scale = scale.bigger() }
            }
            .disabled(scale == .xlarge)

            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)

            ReaderControlButton(
                icon: "xmark",
                help: "Close Reader (Esc)"
            ) { onClose() }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceHover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 8)
    }
}

private struct ReaderControlButton: View {
    let icon: String
    let help: String
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isEnabled
                    ? (isHovering ? Palette.text : Palette.textPrimary)
                    : Palette.textFaint)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering && isEnabled ? Palette.surfaceActive : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(help)
    }
}

// MARK: - Escape key
//
// Installs a window-scoped local event monitor for the Esc key while Reader
// Mode is on screen. Implemented as a local NSEvent monitor (not by stealing
// first-responder) so the article keeps native text selection — clicking
// inside the body still hands focus to the underlying text view.

private struct EscapeKeyCatcher: NSViewRepresentable {
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                var handled = false
                MainActor.assumeIsolated {
                    self?.onEscape()
                    handled = true
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

// MARK: - Theme
//
// Pure black-and-white reader on the app's dark plate. The card sits one
// step above the chrome (`Palette.bgRaised`) so it reads as a lifted
// reading surface, and all body type, hairlines, and accents come from
// the shared `Palette` so Reader Mode never looks like a foreign panel.

private enum ReaderTheme {
    static let surface = Palette.bgRaised
    static let textPrimary = Palette.textPrimary
    static let textSecondary = Palette.textSecondary
    static let textMuted = Palette.textMuted
    static let hairline = Palette.stroke
    static let quoteBar = Palette.strokeStrong
    static let codeInline = Color.white.opacity(0.08)
    static let codeBlock = Palette.bgSunken
    static let imagePlaceholder = Color.white.opacity(0.05)

    static let cardMaxWidth: CGFloat = 720
    static let cardHorizontalPadding: CGFloat = 72
    static let blockSpacing: CGFloat = 18
}
