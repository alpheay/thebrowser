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
