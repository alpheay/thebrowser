import SwiftUI

/// The centerpiece of the intelligent inbox: a preview of an AI-composed email
/// the user can read, edit, regenerate, or send — pinned above the chat
/// composer. It drives all of its actions back through the same `mail_*` tool
/// surface the model uses (`runMailTool`), so there's one code path for sending
/// and one send-permission gate. Nothing leaves the machine until the user
/// acts here (or, in auto-send mode, the model already sent and no card shows).
struct MailDraftCard: View {
    let preview: MailDraftPreview
    /// Human label of the current send mode, shown so the user knows what the
    /// primary button will do.
    let sendModeTitle: String
    let runMailTool: @MainActor (NativeBrowserToolCall) async -> NativeBrowserToolResult
    let onDismiss: () -> Void

    @AppStorage(PreferenceKey.mailSendMode) private var sendModeRaw = MailSendMode.draftOnly.rawValue

    @State private var editedTo: String
    @State private var editedSubject: String
    @State private var editedBody: String
    @State private var isEditing = false
    @State private var isWorking = false
    @State private var status: Status?
    @State private var didComplete = false

    private enum Status: Equatable {
        case info(String)
        case success(String)
        case failure(String)
    }

    init(
        preview: MailDraftPreview,
        sendModeTitle: String,
        runMailTool: @escaping @MainActor (NativeBrowserToolCall) async -> NativeBrowserToolResult,
        onDismiss: @escaping () -> Void
    ) {
        self.preview = preview
        self.sendModeTitle = sendModeTitle
        self.runMailTool = runMailTool
        self.onDismiss = onDismiss
        _editedTo = State(initialValue: preview.to)
        _editedSubject = State(initialValue: preview.subject)
        _editedBody = State(initialValue: preview.body)
    }

    private var sendMode: MailSendMode { MailSendMode(rawValue: sendModeRaw) ?? .draftOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            fields
            if let status { statusRow(status) }
            if !didComplete { actions }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text(preview.isReply ? "Draft reply" : "Draft")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss draft")
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private var fields: some View {
        if isEditing {
            labeledField("To", text: $editedTo)
            labeledField("Subject", text: $editedSubject)
            TextEditor(text: $editedBody)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 220)
                .padding(8)
                .background(Palette.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        } else {
            VStack(alignment: .leading, spacing: 3) {
                metaLine("To", editedTo)
                metaLine("Subject", editedSubject)
            }
            ScrollView {
                Text(editedBody)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 52, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 52, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        }
    }

    // MARK: - Status

    private func statusRow(_ status: Status) -> some View {
        let (icon, tint, text): (String, Color, String) = {
            switch status {
            case .info(let t): return ("info.circle", Palette.textMuted, t)
            case .success(let t): return ("checkmark.circle.fill", Palette.accent, t)
            case .failure(let t): return ("exclamationmark.triangle.fill", Palette.danger, t)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if didComplete {
                Button("Done", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            secondaryButton(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil") {
                withAnimation(Motion.springSnap) { isEditing.toggle() }
            }
            secondaryButton("Regenerate", systemImage: "arrow.triangle.2.circlepath", disabled: isWorking || preview.instructions == nil) {
                Task { await regenerate() }
            }
            Spacer(minLength: 0)
            primaryButton(primaryLabel, systemImage: primaryIcon, busy: isWorking) {
                Task { await primaryAction() }
            }
        }
    }

    private var primaryLabel: String {
        switch sendMode {
        case .draftOnly: return "Open in Composer"
        case .askFirst, .autoSend: return "Send"
        }
    }

    private var primaryIcon: String {
        sendMode == .draftOnly ? "square.and.pencil" : "paperplane.fill"
    }

    // MARK: - Behavior

    private func primaryAction() async {
        isWorking = true
        defer { isWorking = false }

        var call = NativeBrowserToolCall(name: .mailSend)
        call.to = editedTo
        call.cc = preview.cc
        call.subject = editedSubject
        call.body = editedBody
        call.threadID = preview.threadId
        call.messageID = preview.inReplyToMessageId
        // The user clicking the primary button IS the confirmation, so in
        // "ask first" mode we set apply to perform the real send rather than
        // bouncing back another confirm card.
        call.apply = (sendMode == .askFirst)

        let result = await runMailTool(call)
        if result.succeeded {
            if sendMode == .draftOnly {
                status = .info(result.content)
            } else {
                status = .success("Sent to \(editedTo).")
            }
            didComplete = true
        } else {
            status = .failure(result.content)
        }
    }

    private func regenerate() async {
        isWorking = true
        defer { isWorking = false }
        status = .info("Regenerating…")

        var call = NativeBrowserToolCall(name: .mailDraft)
        call.threadID = preview.threadId
        call.messageID = preview.inReplyToMessageId ?? preview.sourceMessageId
        if preview.threadId == nil && preview.inReplyToMessageId == nil { call.to = editedTo }
        call.instructions = preview.instructions
        call.style = preview.style

        let result = await runMailTool(call)
        if case .draft(let fresh) = result.mailPayload {
            withAnimation(Motion.springSnap) {
                editedSubject = fresh.subject
                editedBody = fresh.body
                if !fresh.to.isEmpty { editedTo = fresh.to }
            }
            status = nil
        } else {
            status = .failure(result.succeeded ? "Couldn't regenerate the draft." : result.content)
        }
    }

    // MARK: - Buttons

    private func primaryButton(_ title: String, systemImage: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Palette.bg)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Palette.accent))
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func secondaryButton(_ title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(disabled ? Palette.textFaint : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.chipBackground))
            .overlay(Capsule().stroke(Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
