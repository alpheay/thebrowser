import Combine
import Foundation

/// The intelligent-inbox coordinator. Owns the persistence (`MailStore`) and
/// the reasoning sub-agent (`MailAgent`), exposes the published state the UI
/// observes, and is the one place high-level operations live: triage, voice,
/// drafts, memories, reminders, and — critically — the SINGLE send gate every
/// path funnels through so send-mode can't be bypassed.
///
/// It deliberately does NOT retain `GmailStore` (that would create an ownership
/// cycle in the shell). Gmail access is passed in per call.
@MainActor
final class MailModel: ObservableObject {
    static let shared = MailModel()

    /// Gmail-label namespace used when mirroring AI labels into the account.
    static let labelNamespace = "AI"

    @Published private(set) var labels: [AILabel]
    @Published private(set) var decisionsByID: [String: TriageDecision]
    @Published private(set) var memories: [MailMemory]
    @Published private(set) var reminders: [MailReminder]
    @Published var pendingDrafts: [MailDraftPreview] = []
    /// Memory candidates awaiting the user's "Remember this?" consent.
    @Published var memorySuggestions: [MailMemory] = []
    @Published private(set) var isTriaging = false

    private let store: MailStore
    private let defaults: UserDefaults
    let agent: MailAgent

    private var examples: [TriageExample]
    private(set) var voice: VoiceProfile

    init(store: MailStore = MailStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.agent = MailAgent(workspace: store.agentWorkspaceURL)
        self.labels = store.loadLabels()
        self.examples = store.loadExamples()
        self.memories = store.loadMemories()
        self.reminders = store.loadReminders()
        self.voice = store.loadVoice()
        let decisions = store.loadDecisions()
        self.decisionsByID = Dictionary(decisions.map { ($0.messageID, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: - Settings (live from UserDefaults)

    var sendMode: MailSendMode {
        MailSendMode(rawValue: defaults.string(forKey: PreferenceKey.mailSendMode) ?? "") ?? .draftOnly
    }
    var triageEnabled: Bool { defaults.bool(forKey: PreferenceKey.mailTriageEnabled) }
    var triageConfidence: Double {
        let v = defaults.double(forKey: PreferenceKey.mailTriageConfidence)
        return v == 0 ? 0.6 : v
    }
    var mirrorLabels: Bool { defaults.bool(forKey: PreferenceKey.mailMirrorLabelsToGmail) }
    var readMode: Bool { defaults.bool(forKey: PreferenceKey.mailReadMode) }
    var autocompleteEnabled: Bool { defaults.bool(forKey: PreferenceKey.mailAutocompleteEnabled) }
    var autocompleteThrottle: TimeInterval {
        let v = defaults.integer(forKey: PreferenceKey.mailAutocompleteThrottleSeconds)
        return TimeInterval(v == 0 ? 5 : v)
    }
    var memoryAutoExtract: Bool { defaults.bool(forKey: PreferenceKey.mailMemoryAutoExtract) }

    var enabledLabels: [AILabel] { labels.filter(\.enabled) }

    // MARK: - Triage

    /// AI label names attached to a message (for UI pills).
    func labelNames(forMessageID id: String) -> [String] {
        guard let label = decisionsByID[id]?.label, !label.isEmpty else { return [] }
        return [label]
    }

    func label(named name: String) -> AILabel? { labels.first(where: { $0.name == name }) }

    /// Classifies messages, applying deterministic filters first, then the
    /// model in bounded chunks, committing only decisions at or above the
    /// confidence threshold. Returns the count of newly-applied labels.
    @discardableResult
    func triage(_ summaries: [GmailMessageSummary], gmail: GmailStore, force: Bool = false) async -> Int {
        guard triageEnabled, !summaries.isEmpty, !isTriaging else { return 0 }
        isTriaging = true
        defer { isTriaging = false }

        let labelsSnapshot = enabledLabels
        guard !labelsSnapshot.isEmpty else { return 0 }

        var toClassify: [TriageInput] = []
        for summary in summaries where force || decisionsByID[summary.id] == nil {
            if let match = labelsSnapshot.first(where: { $0.deterministicMatch(fromAddress: summary.fromAddress, subject: summary.subject) }) {
                applyDecision(TriageDecision(messageID: summary.id, label: match.name, confidence: 1.0, reason: "filter"))
            } else {
                toClassify.append(TriageInput(summary: summary))
            }
        }

        var applied = 0
        for chunk in toClassify.chunked(into: 20) {
            let decisions = await agent.classify(chunk, labels: labelsSnapshot, examples: examples)
            for decision in decisions
            where decision.confidence >= triageConfidence
                && labelsSnapshot.contains(where: { $0.name == decision.label }) {
                applyDecision(decision)
                applied += 1
            }
        }
        store.saveDecisions(Array(decisionsByID.values))
        if mirrorLabels {
            await mirrorLabelsToGmail(summaries: summaries, gmail: gmail)
        }
        return applied
    }

    /// User correction → committed decision + a few-shot example for next time.
    func reclassify(messageID: String, to label: String, input: TriageInput, gmail: GmailStore) async {
        applyDecision(TriageDecision(messageID: messageID, label: label, confidence: 1.0, reason: "user"))
        examples.append(TriageExample(subject: input.subject, fromAddress: input.fromAddress, snippet: input.snippet, label: label))
        if examples.count > 40 { examples.removeFirst(examples.count - 40) }
        store.saveExamples(examples)
        store.saveDecisions(Array(decisionsByID.values))
        if mirrorLabels, let summary = decisionSummary(for: messageID, input: input) {
            await mirrorLabelsToGmail(summaries: [summary], gmail: gmail)
        }
    }

    private func applyDecision(_ decision: TriageDecision) {
        decisionsByID[decision.messageID] = decision
    }

    private func decisionSummary(for id: String, input: TriageInput) -> GmailMessageSummary? {
        GmailMessageSummary(id: id, threadId: id, snippet: input.snippet, subject: input.subject, fromName: input.fromName, fromAddress: input.fromAddress, date: Date(), unread: false, starred: false, labelIDs: [])
    }

    private func mirrorLabelsToGmail(summaries: [GmailMessageSummary], gmail: GmailStore) async {
        let used = Set(summaries.compactMap { decisionsByID[$0.id]?.label }.filter { !$0.isEmpty })
        guard !used.isEmpty else { return }
        guard let map = try? await gmail.toolEnsureLabels(namespace: Self.labelNamespace, names: Array(used)) else { return }
        for labelName in used {
            guard let labelID = map[labelName] else { continue }
            let ids = summaries.filter { decisionsByID[$0.id]?.label == labelName }.map(\.id)
            try? await gmail.toolBatchModify(messageIDs: ids, add: [labelID])
        }
    }

    // MARK: - Drafts + the single send gate

    func stageDraft(_ draft: MailDraftPreview) {
        if let idx = pendingDrafts.firstIndex(where: { $0.id == draft.id }) {
            pendingDrafts[idx] = draft
        } else {
            pendingDrafts.append(draft)
        }
    }

    func draft(id: UUID) -> MailDraftPreview? { pendingDrafts.first(where: { $0.id == id }) }
    func removeDraft(id: UUID) { pendingDrafts.removeAll { $0.id == id } }

    /// THE send path. `userInitiated` (the card's Send button) is treated as
    /// explicit approval and always sends; the agent path (`mail_send`) is
    /// subject to send-mode and Read Mode.
    func send(_ draft: MailDraftPreview, gmail: GmailStore, userInitiated: Bool) async -> MailSendResult {
        stageDraft(draft)

        if !userInitiated {
            if readMode { return .stagedForReview(draftID: draft.id) }
            switch sendMode {
            case .draftOnly, .askFirst:
                return .stagedForReview(draftID: draft.id)
            case .autoSend:
                let external = isExternalRecipient(draft.to, accountEmail: gmail.accountEmail)
                let risk = await agent.assessSendRisk(to: draft.to, subject: draft.subject, body: draft.body, isExternal: external)
                if !risk.isLow {
                    return .heldForRisk(draftID: draft.id, reason: risk.reason ?? "Flagged for review.")
                }
            }
        }

        do {
            let id = try await gmail.toolSend(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                threadId: draft.threadId,
                inReplyToMessageID: draft.inReplyToMessageID
            )
            removeDraft(id: draft.id)
            return .sent(id: id)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func isExternalRecipient(_ to: String, accountEmail: String?) -> Bool {
        guard let mine = accountEmail.flatMap(MailText.domain(of:)),
              let theirs = MailText.domain(of: to) else { return true }
        return mine != theirs
    }

    // MARK: - Voice

    func ensureVoiceProfile(gmail: GmailStore) async {
        guard !voice.isUsable else { return }
        guard let bodies = try? await gmail.toolRecentSentBodies(limit: 12), !bodies.isEmpty else { return }
        if let profile = await agent.buildVoiceProfile(fromSent: bodies) {
            voice = profile
            store.saveVoice(voice)
        }
    }

    // MARK: - Memories

    func relevantMemories(forRecipient email: String?) -> [MailMemory] {
        memories.filter { $0.applies(toEmail: email) }
    }

    func addMemory(_ memory: MailMemory) {
        memories.append(memory)
        store.saveMemories(memories)
    }

    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
        store.saveMemories(memories)
    }

    func searchMemories(_ query: String) -> [MailMemory] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return memories }
        return memories.filter { $0.text.lowercased().contains(q) || $0.anchor.label.lowercased().contains(q) }
    }

    /// Runs extraction over a thread and surfaces candidates for consent (does
    /// NOT persist). The UI shows a "Remember this?" affordance; `addMemory`
    /// commits on approval.
    func proposeMemories(fromThread threadText: String, contactEmail: String?) async {
        guard memoryAutoExtract else { return }
        let found = await agent.extractMemories(fromThread: threadText, contactEmail: contactEmail)
        let fresh = found.filter { candidate in
            !memories.contains { $0.text.lowercased() == candidate.text.lowercased() }
                && !memorySuggestions.contains { $0.text.lowercased() == candidate.text.lowercased() }
        }
        memorySuggestions.append(contentsOf: fresh)
    }

    func acceptMemorySuggestion(id: UUID) {
        guard let memory = memorySuggestions.first(where: { $0.id == id }) else { return }
        memorySuggestions.removeAll { $0.id == id }
        addMemory(memory)
    }

    func dismissMemorySuggestion(id: UUID) {
        memorySuggestions.removeAll { $0.id == id }
    }

    // MARK: - Reminders

    func addReminder(_ reminder: MailReminder) {
        reminders.removeAll { $0.threadId == reminder.threadId && $0.kind == reminder.kind && !$0.dismissed }
        reminders.append(reminder)
        store.saveReminders(reminders)
    }

    func dismissReminder(id: UUID) {
        if let idx = reminders.firstIndex(where: { $0.id == id }) {
            reminders[idx].dismissed = true
            store.saveReminders(reminders)
        }
    }

    func dismissReminders(forThread threadId: String) {
        var changed = false
        for idx in reminders.indices where reminders[idx].threadId == threadId && !reminders[idx].dismissed {
            reminders[idx].dismissed = true
            changed = true
        }
        if changed { store.saveReminders(reminders) }
    }

    func dueReminders(now: Date = Date()) -> [MailReminder] {
        reminders.filter { !$0.dismissed && $0.fireAt <= now }.sorted { $0.fireAt < $1.fireAt }
    }

    /// Hardened dropped-ball scan. Groups the inbox by thread, takes the newest
    /// message per thread, and only flags threads where:
    ///   - the latest message is NOT from the user (so we don't nudge threads
    ///     the user already replied to),
    ///   - the sender is a real person (not a no-reply / automated address),
    ///   - it isn't classified Newsletter/Billing,
    ///   - it's older than `days`.
    /// This avoids the prior attempt's false "awaiting your reply" nudges.
    @discardableResult
    func scanDroppedBalls(in summaries: [GmailMessageSummary], accountEmail: String?, days: Int = 3, now: Date = Date()) -> [MailReminder] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let mine = accountEmail?.lowercased()
        var seenThreads = Set<String>()
        var created: [MailReminder] = []

        for summary in summaries {   // newest-first
            guard !seenThreads.contains(summary.threadId) else { continue }
            seenThreads.insert(summary.threadId)

            if let mine, summary.fromAddress.lowercased() == mine { continue }     // user is latest
            if Self.isAutomatedSender(summary.fromAddress) { continue }
            if let label = decisionsByID[summary.id]?.label, ["Newsletter", "Billing"].contains(label) { continue }
            guard summary.date < cutoff else { continue }
            if reminders.contains(where: { $0.threadId == summary.threadId && !$0.dismissed }) { continue }

            let reminder = MailReminder(
                threadId: summary.threadId,
                subject: summary.subject,
                fireAt: now,
                note: "No reply in over \(days) day\(days == 1 ? "" : "s")",
                kind: .droppedBall
            )
            created.append(reminder)
        }
        if !created.isEmpty {
            reminders.append(contentsOf: created)
            store.saveReminders(reminders)
        }
        return created
    }

    static func isAutomatedSender(_ address: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? address.lowercased()
        let markers = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification", "mailer", "bounce", "automated", "alerts", "support+"]
        return markers.contains { local.contains($0) }
    }
}

/// The outcome of routing a draft through the send gate.
enum MailSendResult: Sendable, Equatable {
    case sent(id: String)
    case stagedForReview(draftID: UUID)
    case heldForRisk(draftID: UUID, reason: String)
    case failed(String)
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
