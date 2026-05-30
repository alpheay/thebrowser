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

// MARK: - Intelligent-inbox tool surface
//
// These methods back the `mail_*` AI tools. The `tool*` calls are SILENT —
// they fetch/modify data without mutating the visible inbox, so the agent can
// read and organize mail in the background without yanking the user's view
// around (the old tools' biggest flaw). The `present*` calls are the explicit
// opposite: they're how `mail_show` puts something on screen.
extension GmailStore {
    /// A fresh authorized API service, or throws `notSignedIn`.
    func authorizedAPI() async throws -> GmailAPIService {
        guard account.isSignedIn else { throw GmailAuthError.notSignedIn }
        if let token = await account.currentAccessToken() {
            return GmailAPIService(accessToken: token)
        }
        // Retry once ONLY if the OAuth client wasn't loaded (e.g. the inbox was
        // never opened this session). If it was loaded, a nil token means the
        // refresh itself failed — retrying would just re-hit the token endpoint.
        if account.credentialsState.clientID == nil {
            account.reloadCredentials()
            if let token = await account.currentAccessToken() {
                return GmailAPIService(accessToken: token)
            }
        }
        throw GmailAuthError.notSignedIn
    }

    var accountEmail: String? { account.identity?.email }
    var isSignedInForTools: Bool { account.isSignedIn }

    // MARK: Silent reads / writes

    func toolSearch(
        query: String?,
        mailbox: GmailMailbox?,
        maxResults: Int,
        pageToken: String? = nil
    ) async throws -> GmailAPIService.ListResult {
        let api = try await authorizedAPI()
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await api.listMessages(
            mailbox: mailbox ?? .all,
            query: (trimmed?.isEmpty == false) ? trimmed : nil,
            maxResults: max(1, min(maxResults, 50)),
            pageToken: pageToken
        )
    }

    func toolFetchThread(identifier: MailToolMessageIdentifier) async throws -> [GmailMessage] {
        let api = try await authorizedAPI()
        switch identifier.kind {
        case .message:
            let message = try await api.fetchMessage(id: identifier.value)
            return try await api.fetchThread(id: message.threadId)
        case .thread:
            return try await api.fetchThread(id: identifier.value)
        }
    }

    func toolFetchMessage(id: String) async throws -> GmailMessage {
        let api = try await authorizedAPI()
        return try await api.fetchMessage(id: id)
    }

    /// Batch label change + local reconcile so the visible list (if any) stays
    /// in sync without a full refetch.
    func toolBatchModify(messageIDs: [String], add: [String] = [], remove: [String] = []) async throws {
        guard !messageIDs.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
        let api = try await authorizedAPI()
        try await api.batchModify(messageIDs: messageIDs, add: add, remove: remove)
        for id in messageIDs {
            if remove.contains("INBOX"), selectedMailbox == .inbox {
                messages.removeAll { $0.id == id }
                continue
            }
            updateSummary(id: id) { current in
                var labels = Set(current.labelIDs)
                add.forEach { labels.insert($0) }
                remove.forEach { labels.remove($0) }
                return GmailMessageSummary(
                    id: current.id,
                    threadId: current.threadId,
                    snippet: current.snippet,
                    subject: current.subject,
                    fromName: current.fromName,
                    fromAddress: current.fromAddress,
                    date: current.date,
                    unread: labels.contains("UNREAD"),
                    starred: labels.contains("STARRED"),
                    labelIDs: Array(labels)
                )
            }
        }
    }

    @discardableResult
    func toolSend(
        to: String,
        subject: String,
        body: String,
        threadId: String? = nil,
        inReplyToMessageID: String? = nil
    ) async throws -> String {
        let api = try await authorizedAPI()
        guard let from = account.identity?.email else { throw GmailAuthError.notSignedIn }
        let id = try await api.send(
            to: to,
            subject: subject,
            body: body,
            threadId: threadId,
            inReplyToMessageID: inReplyToMessageID,
            from: from
        )
        // If we're sending a reply for a thread shown in the inbox, refresh so
        // the row reflects the new state on next view.
        return id
    }

    /// Recent Sent-mail bodies with quoted history stripped — the raw material
    /// the agent distills into a voice profile.
    func toolRecentSentBodies(limit: Int = 12) async throws -> [String] {
        let api = try await authorizedAPI()
        let list = try await api.listMessages(mailbox: .sent, maxResults: limit)
        var bodies: [String] = []
        for summary in list.summaries.prefix(limit) {
            guard let full = try? await api.fetchMessage(id: summary.id) else { continue }
            let stripped = MailText.stripQuotedReply(full.plainBody)
            if stripped.count >= 20 { bodies.append(stripped) }
        }
        return bodies
    }

    /// Ensures Gmail labels named "<namespace>/<name>" exist for the given AI
    /// label names, creating any missing ones. Returns name → Gmail label id.
    func toolEnsureLabels(namespace: String, names: [String]) async throws -> [String: String] {
        guard !names.isEmpty else { return [:] }
        let api = try await authorizedAPI()
        let existing = try await api.listLabels()
        var map: [String: String] = [:]
        for name in names {
            let fullName = "\(namespace)/\(name)"
            if let found = existing.first(where: { $0.name == fullName }) {
                map[name] = found.id
            } else if let created = try? await api.createLabel(name: fullName) {
                map[name] = created.id
            }
        }
        return map
    }

    // MARK: Explicit UI surfacing (mail_show)

    func presentSearch(summaries: [GmailMessageSummary], query: String, mailbox: GmailMailbox) {
        selectedMailbox = mailbox
        self.query = query
        messages = summaries
        openMessage = nil
        paneMode = .list
        lastError = nil
    }

    func presentThread(_ thread: [GmailMessage]) {
        if let focused = thread.last ?? thread.first {
            openMessage = focused
            paneMode = .reading(messageID: focused.id)
        }
        lastError = nil
    }

    func presentDraft(to: String, subject: String, body: String, inReplyTo: GmailMessage?) {
        let draft = GmailPaneMode.Draft(to: to, subject: subject, body: body, inReplyTo: inReplyTo)
        paneMode = .composing(draft)
        lastError = nil
    }
}
