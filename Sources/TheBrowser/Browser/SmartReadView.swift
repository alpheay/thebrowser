import AppKit
import Foundation
import SwiftUI

struct SmartReadResult: Equatable {
    var tldr: String
    var keyPoints: [String]
    var readTimeMinutes: Int
    var wordCount: Int
    var title: String
    var url: String
}

@MainActor
final class SmartReadModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading(title: String)
        case loaded(SmartReadResult)
        case failed(String)
    }

    @Published var isPresented = false
    @Published var phase: Phase = .idle
    @Published var anchor = CGPoint(x: 420, y: 180)

    private var task: Task<Void, Never>?

    func start(tab: BrowserTab) {
        guard tab.isSmartReadEligible else {
            return
        }

        task?.cancel()
        anchor = Self.cursorAnchorInKeyWindow()
        isPresented = true
        phase = .loading(title: tab.displayTitle)

        task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let page = await tab.extractReadablePage() else {
                self.phase = .failed("This page does not expose enough readable text for Smart Read.")
                return
            }

            let pageText = page.text
            let wordCount = page.wordCount
            let readTime = max(1, Int(ceil(Double(wordCount) / 230.0)))
            let title = tab.displayTitle
            let url = tab.displayAddress

            do {
                let summary = try await SmartReadClient.summarize(
                    title: title,
                    url: url,
                    text: pageText,
                    readTimeMinutes: readTime,
                    wordCount: wordCount
                )
                guard !Task.isCancelled else { return }
                self.phase = .loaded(summary)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.phase = .failed(message)
            }
        }
    }

    func close() {
        task?.cancel()
        task = nil
        isPresented = false
        phase = .idle
    }

    private static func cursorAnchorInKeyWindow() -> CGPoint {
        guard let window = NSApp.keyWindow else {
            return CGPoint(x: 420, y: 180)
        }

        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: point.x, y: window.frame.height - point.y)
    }

}

enum SmartReadClient {
    static func summarize(
        title: String,
        url: String,
        text: String,
        readTimeMinutes: Int,
        wordCount: Int
    ) async throws -> SmartReadResult {
        let provider = AIHarnessConfiguration.current().provider
        let response = try await AIProviderClient().ask(
            prompt: prompt(
                title: title,
                url: url,
                text: text,
                readTimeMinutes: readTimeMinutes,
                wordCount: wordCount
            ),
            systemPromptOverride: systemPrompt,
            modelOverride: provider.fastModelID
        )

        let payload = try decodeResponse(response)
        return SmartReadResult(
            tldr: payload.tldr.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: payload.keyPoints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            readTimeMinutes: readTimeMinutes,
            wordCount: wordCount,
            title: title,
            url: url
        )
    }

    private static func prompt(
        title: String,
        url: String,
        text: String,
        readTimeMinutes: Int,
        wordCount: Int
    ) -> String {
        """
        Summarize the webpage below for a browser Smart Read popup.

        Return only minified JSON with this exact shape:
        {"tldr":"One concise TL;DR sentence.","key_points":["Point one","Point two","Point three"]}

        Rules:
        - Use the page text only.
        - TL;DR must be one sentence under 32 words.
        - Write 3 to 5 key points.
        - Key points must be concrete, short, and useful.
        - Do not include Markdown, citations, code fences, or extra keys.

        Page:
        Title: \(title)
        URL: \(url)
        Estimated read time: \(readTimeMinutes) min
        Word count: \(wordCount)

        Text:
        \(text)
        """
    }

    private static let systemPrompt = """
    You produce concise webpage summaries for a browser reading popup. Return only valid JSON matching the requested schema. Avoid emojis.
    """

    private static func decodeResponse(_ response: String) throws -> SmartReadPayload {
        let cleaned = cleanedJSON(response)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SmartReadPayload.self, from: data),
              !decoded.tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !decoded.keyPoints.isEmpty else {
            throw SmartReadError.unreadableResponse
        }
        return decoded
    }

    private static func cleanedJSON(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            let withoutFence = lines
                .dropFirst()
                .dropLast(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true ? 1 : 0)
                .joined(separator: "\n")
            return withoutFence.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private struct SmartReadPayload: Decodable {
        var tldr: String
        var keyPoints: [String]

        enum CodingKeys: String, CodingKey {
            case tldr
            case keyPoints = "key_points"
        }
    }
}

enum SmartReadError: LocalizedError {
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .unreadableResponse:
            return "Smart Read could not understand the AI response. Try again in a moment."
        }
    }
}

struct SmartReadOverlay: View {
    @ObservedObject var model: SmartReadModel

    var body: some View {
        GeometryReader { geometry in
            if model.isPresented {
                SmartReadModal(phase: model.phase, onClose: model.close)
                    .frame(width: 430)
                    .position(clampedPosition(in: geometry.size))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
                    .zIndex(20)
            }
        }
        .allowsHitTesting(model.isPresented)
        .animation(Motion.springSnap, value: model.isPresented)
        .animation(Motion.springSnap, value: model.phase)
    }

    private func clampedPosition(in size: CGSize) -> CGPoint {
        let width: CGFloat = 430
        let estimatedHeight: CGFloat = 470
        let margin: CGFloat = 18
        let desiredX = model.anchor.x + width / 2 + 14
        let desiredY = model.anchor.y + estimatedHeight / 2 + 14
        let x = size.width <= width + margin * 2
            ? size.width / 2
            : min(max(desiredX, width / 2 + margin), size.width - width / 2 - margin)
        let y = size.height <= estimatedHeight + margin * 2
            ? size.height / 2
            : min(max(desiredY, estimatedHeight / 2 + margin), size.height - estimatedHeight / 2 - margin)
        return CGPoint(x: x, y: y)
    }
}

private struct SmartReadModal: View {
    let phase: SmartReadModel.Phase
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryStrip
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
            content
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.94))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.34), radius: 28, x: 0, y: 18)
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoading ? "sparkles" : "text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .modifier(SmartReadPulse(active: isLoading))

            Text("Smart Read")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))

            Spacer(minLength: 8)

            if let meta = metaText {
                Text(meta)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(SmartReadIconButtonStyle())
            .help("Close Smart Read")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading(let title):
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(2)
                SmartReadShimmer()
            }
            .padding(18)
        case .loaded(let result):
            loadedContent(result)
                .padding(18)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.70))
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    private func loadedContent(_ result: SmartReadResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("TL;DR")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.34))
                Text(result.tldr)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(result.keyPoints.prefix(5).enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.black)
                            .frame(width: 24, height: 20)
                            .background {
                                Capsule().fill(Color.white.opacity(0.92))
                            }
                        Text(point)
                            .font(.system(size: 13.2, weight: .medium))
                            .lineSpacing(2)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                metricPill("\(result.readTimeMinutes) min", "read")
                metricPill("\(result.wordCount)", "words")
                Spacer(minLength: 0)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private var metaText: String? {
        switch phase {
        case .loaded(let result):
            return "\(result.readTimeMinutes) min read"
        case .loading:
            return "reading"
        case .failed:
            return "paused"
        case .idle:
            return nil
        }
    }

    private func metricPill(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.90))
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.34))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.07))
        }
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct SmartReadShimmer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmartReadShimmerBar(widthFraction: 1.0, delay: 0.0)
            SmartReadShimmerBar(widthFraction: 0.88, delay: 0.06)
            SmartReadShimmerBar(widthFraction: 0.54, delay: 0.12)
            Spacer(minLength: 4)
            SmartReadShimmerBar(widthFraction: 0.95, delay: 0.18)
            SmartReadShimmerBar(widthFraction: 0.78, delay: 0.24)
            SmartReadShimmerBar(widthFraction: 0.70, delay: 0.30)
        }
    }
}

private struct SmartReadShimmerBar: View {
    var widthFraction: CGFloat
    var delay: Double
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * widthFraction
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.32)),
                                .init(color: Color.white.opacity(0.18), location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.32))
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
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    phase = 1.35
                }
            }
        }
    }
}

private struct SmartReadPulse: ViewModifier {
    var active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(active && pulse ? 0.42 : 1)
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
                    withAnimation(.easeOut(duration: 0.16)) {
                        pulse = false
                    }
                }
            }
    }
}

private struct SmartReadIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SmartReadIconButtonBody(configuration: configuration)
    }
}

private struct SmartReadIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(isHovering ? 0.96 : 0.66))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? Color.white.opacity(0.10) : Color.clear)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .onHover { isHovering = $0 }
            .animation(Motion.hoverFade, value: isHovering)
            .animation(Motion.microTap, value: configuration.isPressed)
    }
}
