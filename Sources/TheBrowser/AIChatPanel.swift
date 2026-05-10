import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        case system
    }

    let id = UUID()
    var role: Role
    var text: String
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isSending = false

    private let client = AIProviderClient()

    func send(context: BrowserPageContext) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else {
            return
        }

        messages.append(ChatMessage(role: .user, text: trimmed))
        draft = ""
        isSending = true

        Task {
            do {
                let response = try await client.ask(trimmed, context: context)
                messages.append(ChatMessage(role: .assistant, text: response))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                messages.append(ChatMessage(role: .system, text: message))
            }

            isSending = false
        }
    }
}

struct AIChatPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    var context: BrowserPageContext
    var onClose: () -> Void

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            composer
        }
        .frame(width: Metrics.chatWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(provider.displayName)
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)

            if !context.title.isEmpty || !context.url.isEmpty {
                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textFaint)
                Text(context.title.isEmpty ? "Home" : context.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Hide chat")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .hairline(.bottom)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        ThinkingPulse()
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation(Motion.springSoft) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isSending) { _, isSending in
                if isSending {
                    withAnimation(Motion.springSoft) {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            // Context pill
            if !context.title.isEmpty || !context.url.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Context: \(context.title.isEmpty ? "Home" : context.title)")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(Palette.surface)
                }
                .overlay {
                    Capsule().stroke(Palette.stroke, lineWidth: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if viewModel.draft.isEmpty {
                        Text("Ask \(provider.displayName) anything")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.textMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.draft)
                        .focused($composerFocused)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minHeight: 38, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .onSubmit {
                            viewModel.send(context: context)
                        }
                }
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(composerFocused ? Color.white.opacity(0.16) : Palette.stroke, lineWidth: 1)
                        .animation(.easeOut(duration: 0.12), value: composerFocused)
                }

                SendButton(
                    enabled: !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    sending: viewModel.isSending,
                    action: { viewModel.send(context: context) }
                )
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .hairline(.top)
    }

    private var provider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? .codex
    }
}

// MARK: - Message bubbles

private struct MessageView: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.text)
        case .assistant:
            AssistantMessage(text: message.text)
        case .system:
            SystemPill(text: message.text)
        }
    }
}

private struct UserBubble: View {
    var text: String

    var body: some View {
        HStack {
            Spacer(minLength: 32)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 14,
                        style: .continuous
                    )
                    .fill(Palette.surfaceActive)
                }
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }
}

private struct AssistantMessage: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Leading white bar
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("CODEX")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.textFaint)

                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemPill: View {
    var text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(Palette.surface)
                }
                .overlay {
                    Capsule().stroke(Palette.strokeStrong, lineWidth: 1)
                }
            Spacer()
        }
    }
}

private struct ThinkingPulse: View {
    @State private var phase = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 2, height: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("CODEX")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.textFaint)

                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Palette.textSecondary)
                            .frame(width: 4, height: 4)
                            .scaleEffect(phase == index ? 1.0 : 0.6)
                            .opacity(phase == index ? 1.0 : 0.4)
                    }
                }
                .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            startPulse()
        }
    }

    private func startPulse() {
        Task { @MainActor in
            while !Task.isCancelled {
                for index in 0..<3 {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        phase = index
                    }
                    try? await Task.sleep(nanoseconds: 240_000_000)
                }
            }
        }
    }
}

private struct SendButton: View {
    var enabled: Bool
    var sending: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Palette.bg : Palette.textMuted)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(buttonFill)
                }
                .overlay {
                    Circle()
                        .stroke(enabled ? Color.clear : Palette.stroke, lineWidth: 1)
                }
                .scaleEffect(isHovering && enabled ? 1.04 : 1.0)
                .animation(Motion.springSnap, value: isHovering)
                .animation(Motion.springSnap, value: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || sending)
        .onHover { isHovering = $0 }
        .help("Send")
    }

    private var buttonFill: Color {
        if !enabled { return Palette.surface }
        return Palette.accent
    }
}
