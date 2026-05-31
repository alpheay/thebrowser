import SwiftUI

/// A staged AI draft, shown in the chat panel. Every action — Edit, Regenerate,
/// Rate, Send — routes back through `MailModel`, so the send gate is the single
/// source of truth (the card's Send is treated as the user's explicit
/// approval). Mirrors the `SmartReadCard` precedent in the chat message list.
struct MailDraftCard: View {
    let draft: MailDraftPreview
    @ObservedObject var mail: MailModel
    let gmail: GmailStore

    @State private var body_: String
    @State private var subject: String
    @State private var isEditing = false
    @State private var isWorking = false
    @State private var workingLabel = ""
    @State private var rating: DraftRating?
    @State private var status: String?
    @State private var customInstruction = ""
    @State private var showCustomPrompt = false

    init(draft: MailDraftPreview, mail: MailModel, gmail: GmailStore) {
        self.draft = draft
        self.mail = mail
        self.gmail = gmail
        _body_ = State(initialValue: draft.body)
        _subject = State(initialValue: draft.subject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            recipientRow
            bodyView
            if let rating { ratingView(rating) }
            editToolbar
            actionRow
            if let status {
                Text(status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(12)
        .surfaceCard()
        .alert("Custom edit", isPresented: $showCustomPrompt) {
            TextField("e.g. make it warmer", text: $customInstruction)
            Button("Apply") { runEdit(.custom) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text(draft.isReply ? "Draft reply" : "Draft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if isWorking {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(workingLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textFaint)
                }
            }
            Button { mail.removeDraft(id: draft.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .buttonStyle(.plain)
            .help("Dismiss draft")
        }
    }

    private var recipientRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("To: \(draft.to)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            if isEditing {
                TextField("Subject", text: $subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            } else {
                Text(subject.isEmpty ? "(no subject)" : subject)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        if isEditing {
            TextEditor(text: $body_)
                .font(.system(size: 12, weight: .regular))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 180)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.bg))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.stroke, lineWidth: 1))
        } else {
            ScrollView {
                Text(body_)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        }
    }

    private func ratingView(_ rating: DraftRating) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Score \(rating.score)/100")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(scoreColor(rating.score))
                Text("· \(rating.inferredGoal)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
            ForEach(Array(rating.suggestions.prefix(3).enumerated()), id: \.offset) { _, suggestion in
                Text("• \(suggestion)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.bgRaised))
    }

    private var editToolbar: some View {
        HStack(spacing: 6) {
            ForEach([DraftEditAction.improve, .shorten, .lengthen, .fixGrammar], id: \.self) { action in
                editButton(action)
            }
            editButton(.custom)
        }
    }

    private func editButton(_ action: DraftEditAction) -> some View {
        Button {
            if action == .custom { showCustomPrompt = true } else { runEdit(action) }
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .help(action.title)
        .disabled(isWorking)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { Task { await regenerate() } } label: {
                Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle())
            .disabled(isWorking)

            Button { Task { await rate() } } label: {
                Label("Rate", systemImage: "checklist")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle())
            .disabled(isWorking)

            Button { isEditing.toggle() } label: {
                Text(isEditing ? "Done" : "Edit").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle())

            Spacer(minLength: 0)

            Button { Task { await send() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10, weight: .semibold))
                    Text("Send").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.92)))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
    }

    // MARK: - Actions

    private var currentDraft: MailDraftPreview {
        var copy = draft
        copy.body = body_
        copy.subject = subject
        return copy
    }

    private func send() async {
        isWorking = true; workingLabel = "Sending"; status = nil
        defer { isWorking = false }
        let result = await mail.send(currentDraft, gmail: gmail, userInitiated: true)
        switch result {
        case .sent:
            status = "Sent."   // card is removed by MailModel on success
        case .failed(let message):
            status = "Send failed: \(message)"
        case .stagedForReview, .heldForRisk:
            status = "Staged."
        }
    }

    private func regenerate() async {
        isWorking = true; workingLabel = "Regenerating"; status = nil; rating = nil
        defer { isWorking = false }
        await mail.ensureVoiceProfile(gmail: gmail)
        var threadText = "(new message)"
        if let sourceID = draft.sourceMessageID ?? draft.inReplyToMessageID,
           let thread = try? await gmail.toolFetchThread(identifier: .init(kind: .message, value: sourceID)) {
            threadText = thread.map { "\($0.fromName): \(MailText.stripQuotedReply($0.plainBody))" }.joined(separator: "\n\n")
        }
        let memories = mail.relevantMemories(forRecipient: draft.to)
        if let content = await mail.agent.draft(
            threadText: threadText, instructions: draft.instructions, suggestedSubject: subject,
            recipient: draft.to, voice: mail.voice, memories: memories, style: draft.style
        ) {
            body_ = content.body
            if let newSubject = content.subject, !newSubject.isEmpty { subject = newSubject }
            mail.stageDraft(currentDraft)
        } else {
            status = "Couldn't regenerate."
        }
    }

    private func runEdit(_ action: DraftEditAction) {
        Task {
            isWorking = true; workingLabel = action.title; status = nil
            defer { isWorking = false }
            let custom = action == .custom ? customInstruction : nil
            if let edited = await mail.agent.editDraft(body_, action: action, customInstruction: custom, threadText: nil, voice: mail.voice) {
                body_ = edited
                mail.stageDraft(currentDraft)
            } else {
                status = "Edit didn't return a result."
            }
            customInstruction = ""
        }
    }

    private func rate() async {
        isWorking = true; workingLabel = "Rating"; status = nil
        defer { isWorking = false }
        rating = await mail.agent.rateDraft(body_, goalHint: draft.instructions, threadText: nil)
        if rating == nil { status = "Couldn't rate the draft." }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 75 { return Color(red: 0.55, green: 0.85, blue: 0.62) }
        if score >= 45 { return Color(red: 1.0, green: 0.78, blue: 0.35) }
        return Color(red: 1.0, green: 0.55, blue: 0.55)
    }
}
