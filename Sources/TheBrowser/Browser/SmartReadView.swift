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

    private var task: Task<Void, Never>?

    func start(tab: BrowserTab) {
        guard tab.isSmartReadEligible else {
            return
        }

        task?.cancel()
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

// MARK: - Card

/// Compact Smart Read panel designed to live at the top of the AI chat
/// sidebar. Sized to fit the chat panel width with the same horizontal
/// padding as message bubbles so it visually belongs to the column.
struct SmartReadCard: View {
    let phase: SmartReadModel.Phase
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .animation(Motion.springSnap, value: phase)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Palette.bgRaised)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                Image(systemName: isLoading ? "sparkles" : "text.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .modifier(SmartReadIconPulse(active: isLoading))
            }
            .frame(width: 22, height: 22)

            Text("Smart Read")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 6)

            if let meta = metaText {
                Text(meta)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }

            CardCloseButton(action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading(let title):
            LoadingContent(title: title)
        case .loaded(let result):
            LoadedContent(result: result)
        case .failed(let message):
            FailedContent(message: message)
        }
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private var metaText: String? {
        switch phase {
        case .loaded(let result):
            return "\(result.readTimeMinutes) MIN READ"
        case .loading:
            return "READING"
        case .failed:
            return "PAUSED"
        case .idle:
            return nil
        }
    }
}

// MARK: - Phase content

private struct LoadingContent: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                SmartReadShimmerBar(widthFraction: 1.00, delay: 0.00)
                SmartReadShimmerBar(widthFraction: 0.92, delay: 0.06)
                SmartReadShimmerBar(widthFraction: 0.68, delay: 0.12)
                SmartReadShimmerBar(widthFraction: 0.84, delay: 0.18)
                SmartReadShimmerBar(widthFraction: 0.52, delay: 0.24)
            }
        }
        .padding(14)
    }
}

private struct LoadedContent: View {
    let result: SmartReadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "TL;DR")
                Text(result.tldr)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Key Points")
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(result.keyPoints.prefix(5).enumerated()), id: \.offset) { index, point in
                            KeyPointRow(index: index + 1, text: point)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                MetricPill(value: "\(result.readTimeMinutes) min", label: "READ")
                MetricPill(
                    value: Self.wordCountFormatter.string(from: NSNumber(value: result.wordCount)) ?? "\(result.wordCount)",
                    label: "WORDS"
                )
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private static let wordCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

private struct FailedContent: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

// MARK: - Pieces

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(Palette.textMuted)
    }
}

private struct KeyPointRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 18, height: 18)
                .background {
                    Circle().stroke(Palette.strokeStrong, lineWidth: 1)
                }
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MetricPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background {
            Capsule().fill(Palette.bgRaised)
        }
        .overlay {
            Capsule().stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct CardCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help("Close Smart Read")
    }
}

// MARK: - Shimmer

private struct SmartReadShimmerBar: View {
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
            .frame(width: width, height: 10, alignment: .leading)
        }
        .frame(height: 10)
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

private struct SmartReadIconPulse: ViewModifier {
    var active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(active && pulse ? 0.55 : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: active) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
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
