import AppKit
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
    @Published private(set) var sessionID: String

    private let client = AIProviderClient()
    private let store = ChatSessionStore.shared

    init() {
        self.sessionID = ChatSessionStore.shared.newSessionID()
    }

    /// The directory that backs the current session. Persisted at
    /// ``~/.thebrowser/sessions/<sessionID>``.
    var sessionDirectory: URL {
        store.directory(for: sessionID)
    }

    func send(context: BrowserPageContext) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else {
            return
        }

        messages.append(ChatMessage(role: .user, text: trimmed))
        draft = ""
        isSending = true
        persist(context: context)

        let directory = sessionDirectory
        let history = messages

        Task {
            do {
                let response = try await client.ask(
                    trimmed,
                    context: context,
                    sessionDirectory: directory,
                    history: history
                )
                messages.append(ChatMessage(role: .assistant, text: response))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                messages.append(ChatMessage(role: .system, text: message))
            }

            isSending = false
            persist(context: context)
        }
    }

    func clear() {
        messages.removeAll()
        draft = ""
        sessionID = store.newSessionID()
    }

    private func persist(context: BrowserPageContext) {
        store.save(messages: messages, sessionID: sessionID, pageContext: context)
    }
}

struct AIChatPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    var context: BrowserPageContext
    var onClose: () -> Void

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @FocusState private var composerFocused: Bool
    @State private var showingModelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            composer
        }
        .frame(width: Metrics.chatWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.surface)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                ProviderMark(provider: provider, size: 13)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Chat")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if viewModel.isSending {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 5, height: 5)
                            .modifier(BreathingPulse())
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                Text(provider.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textFaint)
            }

            Spacer(minLength: 8)

            HeaderIconButton(systemName: "square.and.pencil", help: "New conversation") {
                withAnimation(Motion.springSoft) {
                    viewModel.clear()
                }
            }
            .opacity(viewModel.messages.isEmpty ? 0.35 : 1.0)
            .disabled(viewModel.messages.isEmpty)
            .animation(.easeOut(duration: 0.15), value: viewModel.messages.isEmpty)

            HeaderIconButton(systemName: "xmark", help: "Hide chat", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.clear, Palette.stroke, Palette.stroke, Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .animation(Motion.springSnap, value: viewModel.isSending)
    }

    // MARK: - Content (messages or empty state)

    @ViewBuilder
    private var content: some View {
        if viewModel.messages.isEmpty && !viewModel.isSending {
            EmptyChatState(
                providerName: provider.displayName,
                context: context,
                onSuggestion: { text in
                    viewModel.draft = text
                    composerFocused = true
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity
                            ))
                    }

                    if viewModel.isSending {
                        ThinkingShimmer()
                            .id("thinking")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .animation(Motion.springSoft, value: viewModel.messages.count)
                .animation(Motion.springSoft, value: viewModel.isSending)
            }
            .scrollIndicators(.hidden)
            .mask(scrollFadeMask)
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

    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
            Color.black
            LinearGradient(
                colors: [Color.black, Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !context.title.isEmpty || !context.url.isEmpty {
                HStack(spacing: 6) {
                    contextPill
                    Spacer(minLength: 0)
                }
            }

            ComposerField(
                draft: $viewModel.draft,
                focused: $composerFocused,
                placeholder: "Ask \(provider.displayName)…",
                onSubmit: { viewModel.send(context: context) }
            ) {
                HStack(spacing: 6) {
                    ModelPickerButton(
                        provider: provider,
                        showingPicker: $showingModelPicker
                    )
                    SendButton(
                        enabled: !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        sending: viewModel.isSending,
                        action: { viewModel.send(context: context) }
                    )
                }
            }
        }
        .padding(14)
        .padding(.bottom, 4)
    }

    private var provider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? .codex
    }

    private var contextPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 9, weight: .semibold))
            Text(context.title.isEmpty ? "Home" : context.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().stroke(Palette.stroke, lineWidth: 1))
    }

}

// MARK: - Header icon button

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Palette.text : Palette.textSecondary)
                .frame(width: 26, height: 26)
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
        .help(help)
    }
}

// MARK: - Composer field

private struct ComposerField<Trailing: View>: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var onSubmit: () -> Void
    @ViewBuilder var trailingButton: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .focused(focused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 40, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .onSubmit(onSubmit)
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(focused.wrappedValue ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focused.wrappedValue ? Color.white.opacity(0.22) : Palette.stroke, lineWidth: 1)
            }
            .shadow(color: focused.wrappedValue ? Color.white.opacity(0.06) : Color.clear, radius: 12, x: 0, y: 0)
            .animation(.easeOut(duration: 0.16), value: focused.wrappedValue)

            trailingButton()
                .padding(.bottom, 4)
        }
    }
}

// MARK: - Empty state

private struct EmptyChatState: View {
    let providerName: String
    let context: BrowserPageContext
    let onSuggestion: (String) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Palette.surface)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 56, height: 56)
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 4) {
                Text("How can I help?")
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("Ask \(providerName) about this page or anything else.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)

            VStack(spacing: 6) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    SuggestionChip(
                        icon: suggestion.icon,
                        text: suggestion.text,
                        delay: 0.10 + Double(index) * 0.06,
                        appeared: appeared,
                        action: { onSuggestion(suggestion.text) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 24)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.04)) {
                appeared = true
            }
        }
    }

    private var suggestions: [Suggestion] {
        if !context.url.isEmpty {
            return [
                Suggestion(icon: "text.alignleft", text: "Summarize this page"),
                Suggestion(icon: "lightbulb", text: "Explain the key ideas"),
                Suggestion(icon: "questionmark.bubble", text: "What should I ask about this?")
            ]
        }
        return [
            Suggestion(icon: "globe", text: "Find me a great article on…"),
            Suggestion(icon: "lightbulb", text: "Explain a concept simply"),
            Suggestion(icon: "text.bubble", text: "Help me write something")
        ]
    }

    private struct Suggestion {
        let icon: String
        let text: String
    }
}

private struct SuggestionChip: View {
    let icon: String
    let text: String
    let delay: Double
    let appeared: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .opacity(isHovering ? 1 : 0)
                    .offset(x: isHovering ? 0 : -4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.55, dampingFraction: 0.9).delay(delay), value: appeared)
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
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(alignment: .trailing, spacing: 6) {
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
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
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.13),
                                    Color.white.opacity(0.085)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .overlay {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 14,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 14,
                            style: .continuous
                        )
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    }
                    .frame(maxWidth: 270, alignment: .trailing)

                if isHovering {
                    CopyButton(text: text)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }
}

private struct AssistantMessage: View {
    var text: String
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovering {
                    CopyButton(text: text)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .overlay {
                Capsule().stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(Motion.springSnap) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

private struct SystemPill: View {
    var text: String

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().stroke(Palette.strokeStrong, lineWidth: 1))
            Spacer()
        }
    }
}

// MARK: - Thinking indicator

private struct ThinkingShimmer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2, height: 16)

            ShimmerText("Thinking…")
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -0.4

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.textFaint)
            .overlay {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.25)),
                                .init(color: Palette.textPrimary, location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.25))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .mask {
                        Text(text)
                            .font(.system(size: 13, weight: .medium))
                    }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }
}

private struct BreathingPulse: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.25 : 0.85)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// MARK: - Model picker button

private struct ModelPickerButton: View {
    let provider: AIProviderKind
    @Binding var showingPicker: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            showingPicker.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(isHovering || showingPicker ? Palette.surfaceHover : Palette.surface)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(isHovering || showingPicker ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
                    .frame(width: 32, height: 32)
                ProviderMark(provider: provider, size: 14)
                    .foregroundStyle(Palette.textPrimary)
            }
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(Motion.springSnap, value: isHovering)
            .animation(Motion.hoverFade, value: showingPicker)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose model")
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            ModelPickerPopover {
                showingPicker = false
            }
        }
    }
}

// MARK: - Send button

private struct SendButton: View {
    var enabled: Bool
    var sending: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(buttonFill)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(enabled ? Color.clear : Palette.stroke, lineWidth: 1)
                    .frame(width: 32, height: 32)

                if sending {
                    SpinnerArc()
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(enabled ? Palette.bg : Palette.textMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .scaleEffect(scaleValue)
            .shadow(color: enabled && !sending && isHovering ? Color.white.opacity(0.20) : Color.clear, radius: 10, x: 0, y: 0)
            .animation(Motion.springSnap, value: isHovering)
            .animation(Motion.springSnap, value: enabled)
            .animation(.easeOut(duration: 0.18), value: sending)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || sending)
        .onHover { isHovering = $0 }
        .help("Send")
    }

    private var scaleValue: CGFloat {
        if !enabled { return 1 }
        return isHovering ? 1.06 : 1
    }

    private var buttonFill: Color {
        if !enabled { return Palette.surface }
        if sending { return Palette.surfaceActive }
        return Palette.accent
    }
}

private struct SpinnerArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
