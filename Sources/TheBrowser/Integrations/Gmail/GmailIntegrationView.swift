import AppKit
import SwiftUI

/// Slashy-style Gmail launcher. A centered floating card with three
/// columns of state:
///
/// 1. Header: account chip, search field, close button.
/// 2. Sidebar: mailbox shortcuts (Inbox / Starred / Sent / Drafts / All).
/// 3. Pane: list of messages, the reader for a single message, or the
///    compose form. Switching modes is local to the right pane — the
///    header and sidebar never reflow.
struct GmailIntegrationView: View {
    @ObservedObject var store: GmailStore
    @ObservedObject var account: GmailAccountStore
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Palette.stroke)
            Group {
                switch account.credentialsState {
                case .loading:
                    placeholder(icon: "hourglass", title: "Loading credentials…", message: "")
                case .missing(let message):
                    missingCredentialsView(message: message)
                case .ready:
                    if account.isSignedIn {
                        signedInBody
                    } else {
                        signInPrompt
                    }
                }
            }
        }
        .background(Palette.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 38, x: 0, y: 22)
        .sheet(item: $account.pendingWebAuth) { request in
            GmailAuthWebSheet(request: request)
        }
        .onAppear {
            if account.isSignedIn { store.refreshList() }
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            GmailGlyph()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text("Gmail")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let identity = account.identity {
                    Text(identity.email)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                } else {
                    Text("Not signed in")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                }
            }

            searchField
                .frame(maxWidth: 520)

            Spacer(minLength: 0)

            if account.isSignedIn {
                Button {
                    store.startCompose()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Compose")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    }
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            TextField("Search mail", text: Binding(
                get: { store.query },
                set: { store.setQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.textPrimary)
            .focused($searchFocused)
            .onSubmit { store.refreshList() }
            if !store.query.isEmpty {
                Button { store.setQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(searchFocused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        }
        .animation(Motion.hoverFade, value: searchFocused)
        .disabled(!account.isSignedIn)
        .opacity(account.isSignedIn ? 1 : 0.5)
    }

    // MARK: - Signed-in body

    private var signedInBody: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Rectangle().fill(Palette.stroke).frame(width: 1)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(GmailMailbox.allCases) { mailbox in
                MailboxRow(
                    mailbox: mailbox,
                    selected: store.selectedMailbox == mailbox,
                    action: { store.selectMailbox(mailbox) }
                )
            }
            Spacer(minLength: 0)
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Spacer()
                Button {
                    Task { await account.signOut() }
                } label: {
                    Text("Sign out")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pane: some View {
        switch store.paneMode {
        case .list:
            messageList
        case .reading:
            messageReader
        case .composing(let draft):
            ComposeView(
                draft: draft,
                isSending: store.phase == .sending,
                onUpdate: { transform in store.updateDraft(transform) },
                onCancel: { store.cancelCompose() },
                onSend: { store.sendCurrentDraft() }
            )
        }
    }

    private var messageList: some View {
        ZStack(alignment: .top) {
            if store.messages.isEmpty {
                if store.phase == .loadingList {
                    placeholder(icon: "tray", title: "Loading…", message: "")
                } else {
                    placeholder(
                        icon: "tray",
                        title: "Nothing here",
                        message: store.query.isEmpty
                            ? "This mailbox is empty."
                            : "No messages match \u{201C}\(store.query)\u{201D}."
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(groupedMessages, id: \.bucket) { group in
                            sectionHeader(group.bucket.title)
                            ForEach(group.items) { summary in
                                MessageRow(
                                    summary: summary,
                                    onOpen: { store.openMessage(id: summary.id) },
                                    onToggleStar: { store.toggleStar(summary) }
                                )
                                .padding(.horizontal, 6)
                                Divider().opacity(0.18).padding(.leading, 18)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }

            if store.phase == .loadingList && !store.messages.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
    }

    private var messageReader: some View {
        Group {
            if let message = store.openMessage {
                MessageReader(
                    message: message,
                    onBack: { store.backToList() },
                    onReply: { store.startCompose(replyingTo: message) },
                    onArchive: { store.archiveCurrent() }
                )
            } else if store.phase == .loadingMessage {
                placeholder(icon: "ellipsis", title: "Loading message…", message: "")
            } else {
                placeholder(icon: "envelope", title: "Pick a message", message: "Select something from the inbox to read it here.")
            }
        }
    }

    // MARK: - Sign in / credentials prompts

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.textPrimary.opacity(0.9))
            VStack(spacing: 4) {
                Text("Connect Gmail")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Sign in once and your inbox shows up here. Tokens stay in the macOS Keychain.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = account.lastError {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await account.signIn() }
            } label: {
                HStack(spacing: 8) {
                    if account.phase == .signingIn {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    }
                    Text(account.phase == .signingIn ? "Signing in…" : "Sign in with Google")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(account.phase == .signingIn)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func missingCredentialsView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.35))
                Text("Gmail credentials missing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }

            Text("Drop your OAuth Desktop client JSON at:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            Text(IntegrationCredentialsLoader.defaultLocation(for: "Gmail").path)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.bgRaised)
                }

            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    let path = IntegrationCredentialsLoader.defaultLocation(for: "Gmail")
                        .deletingLastPathComponent()
                    try? FileManager.default.createDirectory(
                        at: path,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(path)
                } label: {
                    Text("Reveal folder").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle())

                Button {
                    account.reloadCredentials()
                } label: {
                    Text("Reload").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle())

                Spacer()
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(40)
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct MessageGroup {
        let bucket: GmailDateBucket
        let items: [GmailMessageSummary]
    }

    private var groupedMessages: [MessageGroup] {
        let now = Date()
        var buckets: [GmailDateBucket: [GmailMessageSummary]] = [:]
        for message in store.messages {
            buckets[GmailDateBucket.bucket(for: message.date, now: now), default: []].append(message)
        }
        return GmailDateBucket.allCases.compactMap { bucket in
            guard let items = buckets[bucket], !items.isEmpty else { return nil }
            return MessageGroup(bucket: bucket, items: items)
        }
    }
}

// MARK: - Subviews

private struct MailboxRow: View {
    let mailbox: GmailMailbox
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mailbox.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, alignment: .center)
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                Text(mailbox.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundFill)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.hoverFade, value: selected)
    }

    private var backgroundFill: Color {
        if selected { return Color.white.opacity(0.08) }
        if isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }
}

private struct MessageRow: View {
    let summary: GmailMessageSummary
    let onOpen: () -> Void
    let onToggleStar: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(summary.unread ? Color.white : Color.clear)
                        .frame(width: 6, height: 6)
                }
                .frame(width: 12)
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(summary.fromName.isEmpty ? summary.fromAddress : summary.fromName)
                            .font(.system(size: 12.5, weight: summary.unread ? .semibold : .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(relativeDate)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.textFaint)
                    }
                    Text(summary.subject)
                        .font(.system(size: 12, weight: summary.unread ? .semibold : .medium))
                        .foregroundStyle(summary.unread ? Palette.textPrimary : Palette.textSecondary)
                        .lineLimit(1)
                    Text(summary.snippet)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(2)
                }

                Button(action: onToggleStar) {
                    Image(systemName: summary.starred ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(summary.starred
                                         ? Color(red: 1.0, green: 0.78, blue: 0.35)
                                         : Palette.textFaint)
                }
                .buttonStyle(.plain)
                .opacity(summary.starred || isHovering ? 1 : 0)
                .padding(.top, 4)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var relativeDate: String {
        let now = Date()
        let cal = Calendar.current
        if cal.isDateInToday(summary.date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: summary.date)
        }
        if cal.isDateInYesterday(summary.date) {
            return "Yesterday"
        }
        let daysAgo = cal.dateComponents([.day], from: summary.date, to: now).day ?? 0
        if daysAgo < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: summary.date)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: summary.date)
    }
}

private struct MessageReader: View {
    let message: GmailMessage
    let onBack: () -> Void
    let onReply: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Back to inbox")

                Spacer()

                Button(action: onArchive) {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Archive")

                Button(action: onReply) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Reply").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }
                    .foregroundStyle(Palette.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Palette.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(message.subject)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.fromName.isEmpty ? message.fromAddress : message.fromName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text("to \(message.to)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.textMuted)
                        }
                        Spacer()
                        Text(absoluteDate)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textFaint)
                    }

                    Divider().background(Palette.strokeFaint)

                    Text(bodyText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Palette.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var bodyText: String {
        if !message.plainBody.isEmpty {
            return message.plainBody
        }
        if let html = message.htmlBody, !html.isEmpty {
            return GmailHTMLToText.convert(html)
        }
        return message.snippet
    }

    private var absoluteDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: message.date)
    }
}

private struct ComposeView: View {
    let draft: GmailPaneMode.Draft
    let isSending: Bool
    let onUpdate: ((inout GmailPaneMode.Draft) -> Void) -> Void
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(draft.inReplyTo == nil ? "New Message" : "Reply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle())
                Button(action: onSend) {
                    HStack(spacing: 6) {
                        if isSending {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isSending ? "Sending…" : "Send")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    }
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Palette.stroke)

            VStack(spacing: 8) {
                composeField(label: "To", text: Binding(
                    get: { draft.to },
                    set: { value in onUpdate { $0.to = value } }
                ))
                composeField(label: "Subject", text: Binding(
                    get: { draft.subject },
                    set: { value in onUpdate { $0.subject = value } }
                ))

                TextEditor(text: Binding(
                    get: { draft.body },
                    set: { value in onUpdate { $0.body = value } }
                ))
                .font(.system(size: 13, weight: .regular))
                .scrollContentBackground(.hidden)
                .background(Palette.bg)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
            }
            .padding(16)
        }
    }

    private func composeField(label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.textFaint)
                .frame(width: 56, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

// MARK: - HTML to text (best-effort)

private enum GmailHTMLToText {
    /// Rough HTML → text. Gmail bodies are wildly varied; we just want
    /// something legible until a full HTML renderer lands. Strips tags,
    /// preserves <br>/<p> as newlines, and decodes the most common
    /// entities.
    static func convert(_ html: String) -> String {
        var output = html
            .replacingOccurrences(of: "(?i)<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (escape, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")
        ] {
            output = output.replacingOccurrences(of: escape, with: replacement)
        }
        return output
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Glyph

private struct GmailGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.95, green: 0.32, blue: 0.28), Color(red: 0.85, green: 0.18, blue: 0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Image(systemName: "envelope.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
