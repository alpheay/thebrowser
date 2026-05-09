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
    @Published var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "I am wired through Codex CLI. Ask me to reason about the current page, draft something, or help shape the next task.")
    ]
    @Published var draft = ""
    @Published var isSending = false

    private let client = CodexCLIClient()

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

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Palette.stroke)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.isSending {
                            ThinkingRow()
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastID = viewModel.messages.last?.id {
                        withAnimation(.snappy) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            composer
        }
        .frame(width: 380)
        .background(Palette.graphite)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.pearl)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.pearl)
                Text(context.url.isEmpty ? "Home context" : context.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(IconButtonStyle())
            .help("Hide AI chat")
        }
        .padding(14)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Codex", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.system(size: 14))
                    .padding(12)
                    .glassPanel()
                    .onSubmit {
                        viewModel.send(context: context)
                    }

                Button {
                    viewModel.send(context: context)
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(IconButtonStyle(selected: !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .disabled(viewModel.isSending)
                .help("Send")
            }
        }
        .padding(14)
        .background(Palette.ink.opacity(0.74))
    }
}

private struct ChatBubble: View {
    var message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 32)
            }

            Text(message.text)
                .font(.system(size: 13.5))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                }
                .frame(maxWidth: 310, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 32)
            }
        }
    }

    private var foreground: Color {
        switch message.role {
        case .user:
            Palette.ink
        case .assistant:
            Palette.pearl
        case .system:
            Palette.saffron
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            Palette.pearl
        case .assistant:
            Color.white.opacity(0.08)
        case .system:
            Palette.saffron.opacity(0.09)
        }
    }

    private var stroke: Color {
        switch message.role {
        case .user:
            Color.white.opacity(0.2)
        case .assistant:
            Palette.stroke
        case .system:
            Palette.saffron.opacity(0.24)
        }
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Codex is thinking")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
