import Combine
import Foundation

/// Drives the Gmail integration view. Holds the currently-selected mailbox,
/// the message list, the open message (if any), and a small bag of
/// state-machine flags (loading, error). All Gmail API calls funnel through
/// here so the view doesn't reach into the API service directly.
@MainActor
final class GmailStore: ObservableObject {
    @Published var selectedMailbox: GmailMailbox = .inbox
    @Published var query: String = ""
    @Published var messages: [GmailMessageSummary] = []
    @Published var openMessage: GmailMessage?
    @Published var paneMode: GmailPaneMode = .list
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?

    enum Phase: Equatable {
        case idle
        case loadingList
        case loadingMessage
        case sending
    }

    private let account: GmailAccountStore
    private var listTask: Task<Void, Never>?
    private var searchDebounce: Task<Void, Never>?

    init(account: GmailAccountStore = .shared) {
        self.account = account
    }

    /// Loads (or reloads) the current mailbox using the current query.
    /// Cancels any in-flight request so quick mailbox switches don't race.
    func refreshList(force: Bool = false) {
        listTask?.cancel()
        listTask = Task { [weak self] in
            await self?.performRefresh()
        }
        if force { openMessage = nil; paneMode = .list }
    }

    func selectMailbox(_ mailbox: GmailMailbox) {
        guard mailbox != selectedMailbox else { return }
        selectedMailbox = mailbox
        paneMode = .list
        openMessage = nil
        refreshList()
    }

    func setQuery(_ query: String) {
        self.query = query
        // Debounce so we don't hammer the API on every keystroke.
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performRefresh()
        }
    }

    func openMessage(id: String) {
        paneMode = .reading(messageID: id)
        Task { [weak self] in
            guard let self else { return }
            self.phase = .loadingMessage
            defer { self.phase = .idle }
            guard let token = await self.account.currentAccessToken() else {
                self.lastError = "Sign in to view this message."
                return
            }
            do {
                let api = GmailAPIService(accessToken: token)
                let full = try await api.fetchMessage(id: id)
                self.openMessage = full
                if full.unread {
                    _ = try? await api.modifyLabels(messageID: id, remove: ["UNREAD"])
                    self.markLocallyRead(id: id)
                }
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func startCompose(replyingTo message: GmailMessage? = nil) {
        var draft = GmailPaneMode.Draft()
        if let message {
            draft.inReplyTo = message
            draft.to = message.fromAddress
            draft.subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
            let quoted = message.plainBody
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")
            draft.body = "\n\nOn \(formatted(message.date)), \(message.fromName) wrote:\n\(quoted)\n"
        }
        paneMode = .composing(draft)
    }

    func updateDraft(_ transform: (inout GmailPaneMode.Draft) -> Void) {
        guard case .composing(var draft) = paneMode else { return }
        transform(&draft)
        paneMode = .composing(draft)
    }

    func cancelCompose() {
        paneMode = .list
    }

    func backToList() {
        openMessage = nil
        paneMode = .list
    }

    func sendCurrentDraft() {
        guard case .composing(let draft) = paneMode else { return }
        let trimmedTo = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTo.isEmpty else {
            lastError = "Add a recipient before sending."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            self.phase = .sending
            defer { self.phase = .idle }
            guard let token = await self.account.currentAccessToken(),
                  let from = self.account.identity?.email else {
                self.lastError = "Sign in to send this message."
                return
            }
            let api = GmailAPIService(accessToken: token)
            do {
                _ = try await api.send(draft: draft, from: from)
                self.paneMode = .list
                self.refreshList(force: true)
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func toggleStar(_ summary: GmailMessageSummary) {
        Task { [weak self] in
            guard let self, let token = await self.account.currentAccessToken() else { return }
            let api = GmailAPIService(accessToken: token)
            let nextStarred = !summary.starred
            // Optimistic update.
            self.updateSummary(id: summary.id) { current in
                var copy = current
                let starred = nextStarred
                copy = GmailMessageSummary(
                    id: copy.id,
                    threadId: copy.threadId,
                    snippet: copy.snippet,
                    subject: copy.subject,
                    fromName: copy.fromName,
                    fromAddress: copy.fromAddress,
                    date: copy.date,
                    unread: copy.unread,
                    starred: starred,
                    labelIDs: copy.labelIDs
                )
                return copy
            }
            do {
                if nextStarred {
                    _ = try await api.modifyLabels(messageID: summary.id, add: ["STARRED"])
                } else {
                    _ = try await api.modifyLabels(messageID: summary.id, remove: ["STARRED"])
                }
            } catch {
                // Roll back on failure.
                self.updateSummary(id: summary.id) { _ in summary }
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func archiveCurrent() {
        guard let open = openMessage else { return }
        Task { [weak self] in
            guard let self, let token = await self.account.currentAccessToken() else { return }
            let api = GmailAPIService(accessToken: token)
            do {
                _ = try await api.modifyLabels(messageID: open.id, remove: ["INBOX"])
                self.messages.removeAll { $0.id == open.id }
                self.backToList()
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func searchForTool(
        query: String,
        mailbox: GmailMailbox?,
        maxResults: Int
    ) async throws -> [GmailMessageSummary] {
        guard account.isSignedIn else { throw GmailAuthError.notSignedIn }
        guard let token = await account.currentAccessToken() else { throw GmailAuthError.notSignedIn }

        phase = .loadingList
        defer { phase = .idle }

        let api = GmailAPIService(accessToken: token)
        let resolvedMailbox = mailbox ?? .all
        let result = try await api.listMessages(
            mailbox: resolvedMailbox,
            query: query,
            maxResults: maxResults
        )

        selectedMailbox = resolvedMailbox
        self.query = query
        messages = result.summaries
        openMessage = nil
        paneMode = .list
        lastError = nil
        return result.summaries
    }

    func readThreadForTool(identifier: MailToolMessageIdentifier) async throws -> [GmailMessage] {
        guard account.isSignedIn else { throw GmailAuthError.notSignedIn }
        guard let token = await account.currentAccessToken() else { throw GmailAuthError.notSignedIn }

        phase = .loadingMessage
        defer { phase = .idle }

        let api = GmailAPIService(accessToken: token)
        let thread: [GmailMessage]
        switch identifier.kind {
        case .message:
            let message = try await api.fetchMessage(id: identifier.value)
            thread = try await api.fetchThread(id: message.threadId)
        case .thread:
            thread = try await api.fetchThread(id: identifier.value)
        }

        if let focused = thread.last ?? thread.first {
            openMessage = focused
            paneMode = .reading(messageID: focused.id)
        }
        lastError = nil
        return thread
    }

    @discardableResult
    func draftReplyForTool(identifier: MailToolMessageIdentifier, body: String) async throws -> GmailMessage {
        let thread = try await readThreadForTool(identifier: identifier)
        guard let target = thread.last ?? thread.first else {
            throw GmailAPIError.decoding("Thread did not contain any messages.")
        }

        let subject = target.subject.lowercased().hasPrefix("re:")
            ? target.subject
            : "Re: \(target.subject)"

        let draft = GmailPaneMode.Draft(
            to: target.fromAddress,
            subject: subject,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            inReplyTo: target
        )

        openMessage = target
        paneMode = .composing(draft)
        lastError = nil
        return target
    }

    // MARK: - Intelligent inbox tool support

    /// Paginated search for the rebuilt mail tools. Returns the page (summaries
    /// + nextPageToken). On a fresh search (`pageToken == nil`) it replaces the
    /// overlay list; on a follow-up page it appends, so "load more" works in
    /// the UI too. Unlike the old tool path it does NOT force the overlay open.
    func searchPaged(
        query: String,
        mailbox: GmailMailbox?,
        maxResults: Int,
        pageToken: String?
    ) async throws -> GmailAPIService.ListResult {
        guard account.isSignedIn else { throw GmailAuthError.notSignedIn }
        guard let token = await account.currentAccessToken() else { throw GmailAuthError.notSignedIn }

        phase = .loadingList
        defer { phase = .idle }

        let api = GmailAPIService(accessToken: token)
        let resolvedMailbox = mailbox ?? .all
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await api.listMessages(
            mailbox: resolvedMailbox,
            query: trimmed.isEmpty ? nil : trimmed,
            maxResults: maxResults,
            pageToken: pageToken
        )

        selectedMailbox = resolvedMailbox
        self.query = trimmed
        if pageToken == nil {
            messages = result.summaries
        } else {
            let existing = Set(messages.map(\.id))
            messages.append(contentsOf: result.summaries.filter { !existing.contains($0.id) })
        }
        openMessage = nil
        paneMode = .list
        lastError = nil
        return result
    }

    /// Batch label modify (archive, mark read/unread, star, add/remove labels)
    /// for the `mail_modify` tool. Applies the change to every id concurrently,
    /// then reconciles the in-memory list optimistically.
    func modify(messageIDs: [String], add: [String] = [], remove: [String] = []) async throws {
        let ids = messageIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        guard let token = await account.currentAccessToken() else { throw GmailAuthError.notSignedIn }
        let api = GmailAPIService(accessToken: token)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = try await api.modifyLabels(messageID: id, add: add, remove: remove) }
            }
            try await group.waitForAll()
        }

        // Optimistic local reconcile so the overlay reflects the change
        // before the next refresh.
        if remove.contains("INBOX") {
            messages.removeAll { ids.contains($0.id) }
        }
        for id in ids {
            updateSummary(id: id) { current in
                var unread = current.unread
                var starred = current.starred
                if add.contains("UNREAD") { unread = true }
                if remove.contains("UNREAD") { unread = false }
                if add.contains("STARRED") { starred = true }
                if remove.contains("STARRED") { starred = false }
                var labels = Set(current.labelIDs)
                labels.formUnion(add)
                labels.subtract(remove)
                return GmailMessageSummary(
                    id: current.id,
                    threadId: current.threadId,
                    snippet: current.snippet,
                    subject: current.subject,
                    fromName: current.fromName,
                    fromAddress: current.fromAddress,
                    date: current.date,
                    unread: unread,
                    starred: starred,
                    labelIDs: Array(labels)
                )
            }
        }
    }

    /// Sends a message from raw fields (the `mail_send` tool's "ask"/"auto"
    /// paths). Replies thread when `threadId` / `inReplyToMessageId` are set.
    @discardableResult
    func sendMessage(
        to: String,
        cc: String?,
        subject: String,
        body: String,
        threadId: String?,
        inReplyToMessageId: String?
    ) async throws -> String {
        guard let token = await account.currentAccessToken(),
              let from = account.identity?.email else {
            throw GmailAuthError.notSignedIn
        }
        phase = .sending
        defer { phase = .idle }
        let api = GmailAPIService(accessToken: token)
        let id = try await api.send(
            to: to,
            cc: cc,
            subject: subject,
            body: body,
            threadId: threadId,
            inReplyToMessageId: inReplyToMessageId,
            from: from
        )
        if selectedMailbox == .sent { refreshList(force: true) }
        return id
    }

    /// Stages a draft in the composer (the draft-only send mode). Opens the
    /// compose pane pre-filled; the user reviews and sends from the UI.
    func stageDraft(
        to: String,
        cc: String?,
        subject: String,
        body: String,
        replyToMessageId: String?,
        threadId: String?
    ) {
        var draft = GmailPaneMode.Draft(to: to, subject: subject, body: body)
        if let openMessage, openMessage.id == replyToMessageId || openMessage.threadId == threadId {
            draft.inReplyTo = openMessage
        }
        paneMode = .composing(draft)
    }

    /// Returns the top (non-quoted) text of recent Sent messages, used once to
    /// distill the user's voice profile. Strips quoted replies so the sample
    /// reflects what the user actually wrote.
    func recentSentBodies(limit: Int = 40) async throws -> [String] {
        guard let token = await account.currentAccessToken() else { throw GmailAuthError.notSignedIn }
        let api = GmailAPIService(accessToken: token)
        let list = try await api.listMessages(mailbox: .sent, query: nil, maxResults: limit)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            for summary in list.summaries {
                group.addTask {
                    let full = try? await api.fetchMessage(id: summary.id)
                    return full.map { Self.topReplyText($0.plainBody) }
                }
            }
            var bodies: [String] = []
            for try await body in group {
                if let body, body.count > 20 { bodies.append(body) }
            }
            return bodies
        }
    }

    /// Keeps the lines a person actually typed at the top of a reply, dropping
    /// the quoted history ("On … wrote:", lines beginning with ">").
    nonisolated private static func topReplyText(_ body: String) -> String {
        var kept: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { break }
            if trimmed.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if trimmed.range(of: #"^-{2,}\s*Forwarded message"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    private func performRefresh() async {
        guard account.isSignedIn else {
            messages = []
            return
        }
        phase = .loadingList
        defer { phase = .idle }
        guard let token = await account.currentAccessToken() else {
            lastError = "Couldn't refresh access — try signing in again."
            return
        }
        let api = GmailAPIService(accessToken: token)
        do {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await api.listMessages(
                mailbox: selectedMailbox,
                query: trimmedQuery.isEmpty ? nil : trimmedQuery,
                maxResults: 30
            )
            if Task.isCancelled { return }
            messages = result.summaries
            lastError = nil
        } catch {
            if Task.isCancelled { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func markLocallyRead(id: String) {
        updateSummary(id: id) { current in
            GmailMessageSummary(
                id: current.id,
                threadId: current.threadId,
                snippet: current.snippet,
                subject: current.subject,
                fromName: current.fromName,
                fromAddress: current.fromAddress,
                date: current.date,
                unread: false,
                starred: current.starred,
                labelIDs: current.labelIDs.filter { $0 != "UNREAD" }
            )
        }
    }

    private func updateSummary(id: String, transform: (GmailMessageSummary) -> GmailMessageSummary) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = transform(messages[idx])
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
}
