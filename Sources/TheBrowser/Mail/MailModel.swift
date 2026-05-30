import Combine
import Foundation

/// The coordinator for TheBrowser's intelligent inbox. Owns the mail
/// sub-agent and the four local stores (triage, memories, reminders, voice)
/// and exposes the high-level operations the tool harness, the Gmail overlay,
/// and the background hooks all call. It deliberately does NOT hold a
/// reference to `GmailStore`: callers fetch Gmail data and hand it in, which
/// keeps ownership a simple tree (BrowserShellView → MailModel, GmailStore)
/// with no retain cycles.
@MainActor
final class MailModel: ObservableObject {
    /// Shared instance. The inbox stores are file-backed singletons in spirit
    /// (one user, one ~/.thebrowser/mail), so the browser window and the
    /// Settings window must edit the same in-memory copy or label/memory edits
    /// wouldn't show up until relaunch.
    static let shared = MailModel()

    let agent = MailAgent()
    let triage = MailTriageStore()
    let memories = MailMemoryStore()
    let reminders = MailReminderStore()
    let voice = VoiceProfileStore()

    /// Auto-extracted memories awaiting the user's keep/discard decision.
    @Published var pendingMemories: [MailMemory] = []
    /// True while a background classify pass is running, so overlapping inbox
    /// loads don't spawn duplicate fast-model calls.
    @Published private(set) var isClassifying = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings accessors

    var sendMode: MailSendMode {
        MailSendMode(rawValue: defaults.string(forKey: PreferenceKey.mailSendMode) ?? "") ?? .draftOnly
    }
    var triageEnabled: Bool { defaults.bool(forKey: PreferenceKey.mailTriageEnabled) }
    var mirrorLabelsToGmail: Bool { defaults.bool(forKey: PreferenceKey.mailMirrorLabelsToGmail) }
    var droppedBallEnabled: Bool { defaults.bool(forKey: PreferenceKey.mailDroppedBallEnabled) }
    var droppedBallDays: Int { max(1, defaults.integer(forKey: PreferenceKey.mailDroppedBallDays)) }
    var memoryAutoExtractEnabled: Bool { defaults.bool(forKey: PreferenceKey.mailMemoryAutoExtract) }

    // MARK: - Triage

    /// Classifies any not-yet-labeled messages among `summaries`. Returns the
    /// new decisions (already applied to the store). Safe to call on every
    /// inbox refresh — it skips already-classified mail and is a no-op when
    /// triage is disabled.
    @discardableResult
    func classifyIfNeeded(_ summaries: [GmailMessageSummary], force: Bool = false) async -> [TriageDecision] {
        guard triageEnabled || force else { return [] }
        guard !isClassifying else { return [] }
        let pending = summaries.filter { force || !triage.isClassified($0.id) }
        guard !pending.isEmpty else { return [] }
        isClassifying = true
        defer { isClassifying = false }

        let inputs = pending.map { summary in
            TriageInput(
                messageId: summary.id,
                from: summary.fromName.isEmpty ? summary.fromAddress : "\(summary.fromName) <\(summary.fromAddress)>",
                subject: summary.subject,
                snippet: summary.snippet
            )
        }
        let decisions = await agent.classify(inputs, labels: triage.enabledLabels, examples: triage.examples)
        triage.apply(decisions)
        return decisions
    }

    /// One entry point for everything that should happen when the inbox list
    /// loads: classify new mail, scan for dropped balls, and surface any due
    /// reminders. Safe to call on every inbox refresh — each step is guarded or
    /// throttled. Only acts on the inbox mailbox.
    func processInboxLoad(_ summaries: [GmailMessageSummary]) {
        scanDroppedBalls(inbox: summaries)
        fireDueReminders()
        Task { await classifyIfNeeded(summaries) }
    }

    /// The user re-labeled a message in the overlay. Persist the correction
    /// and feed it back as a future example.
    func reclassify(summary: GmailMessageSummary, toLabelId labelId: String) {
        let input = TriageInput(
            messageId: summary.id,
            from: summary.fromName.isEmpty ? summary.fromAddress : "\(summary.fromName) <\(summary.fromAddress)>",
            subject: summary.subject,
            snippet: summary.snippet
        )
        triage.recordCorrection(messageId: summary.id, from: input, toLabelId: labelId)
    }

    // MARK: - Voice profile

    /// Ensures a voice profile exists (and is fresh), building it from the
    /// supplied Sent bodies. No-op when the cached profile is still current.
    func ensureVoiceProfile(sentBodies: @autoclosure () async -> [String]) async {
        guard voice.needsRefresh, !voice.isBuilding else { return }
        voice.setBuilding(true)
        defer { voice.setBuilding(false) }
        let bodies = await sentBodies()
        guard !bodies.isEmpty else { return }
        if let profile = await agent.buildVoiceProfile(from: bodies) {
            voice.set(profile)
        }
    }

    // MARK: - Memories

    /// Auto-extracts memories from a thread the user just read or sent, queues
    /// the genuinely new ones for confirmation, and returns them. No-op when
    /// auto-extract is disabled.
    @discardableResult
    func autoExtractMemories(fromThread threadText: String, contactEmail: String?) async -> [MailMemory] {
        guard memoryAutoExtractEnabled else { return [] }
        let candidates = await agent.extractMemories(from: threadText, contactEmail: contactEmail)
        guard !candidates.isEmpty else { return [] }
        let fresh = candidates.filter { cand in
            !memories.memories.contains { $0.text.lowercased() == cand.text.lowercased() && $0.anchor == cand.anchor }
                && !pendingMemories.contains { $0.text.lowercased() == cand.text.lowercased() }
        }
        pendingMemories.append(contentsOf: fresh)
        // Offer each new memory for keeping via a quiet toast. Dismissing the
        // toast simply leaves it unsaved — we never persist without consent.
        for memory in fresh {
            AppNotificationCenter.shared.post(
                title: "Remember this?",
                message: memory.text,
                kind: .info,
                duration: 8,
                actionLabel: "Keep",
                action: { [weak self] in self?.keepPendingMemory(id: memory.id) }
            )
        }
        return fresh
    }

    func keepPendingMemory(id: UUID) {
        guard let idx = pendingMemories.firstIndex(where: { $0.id == id }) else { return }
        var memory = pendingMemories.remove(at: idx)
        memory.confirmed = true
        memory.source = "auto"
        memories.add(memory)
    }

    func discardPendingMemory(id: UUID) {
        pendingMemories.removeAll { $0.id == id }
    }

    // MARK: - Dropped-ball scanner

    /// Scans inbox summaries for threads awaiting the user's reply longer than
    /// the configured threshold and adds dropped-ball reminders for them.
    /// Returns the newly-added reminders. Conservative by design: one reminder
    /// per thread, skips threads that already have one, and only considers
    /// messages whose latest sender isn't the user.
    @discardableResult
    func scanDroppedBalls(inbox summaries: [GmailMessageSummary]) -> [MailReminder] {
        guard droppedBallEnabled else { return [] }
        let userEmail = GmailAccountStore.shared.identity?.email.lowercased()
        let threshold = Date().addingTimeInterval(-Double(droppedBallDays) * 24 * 60 * 60)

        // Latest message per thread.
        var latestByThread: [String: GmailMessageSummary] = [:]
        for summary in summaries {
            if let existing = latestByThread[summary.threadId], existing.date >= summary.date { continue }
            latestByThread[summary.threadId] = summary
        }

        var added: [MailReminder] = []
        for summary in latestByThread.values {
            guard summary.date < threshold else { continue }
            // Skip mail the user sent themselves (last word was theirs).
            if let userEmail, summary.fromAddress.lowercased() == userEmail { continue }
            guard !reminders.hasReminder(threadId: summary.threadId) else { continue }

            let reminder = MailReminder(
                threadId: summary.threadId,
                messageId: summary.id,
                subject: summary.subject,
                from: summary.fromName.isEmpty ? summary.fromAddress : summary.fromName,
                dueAt: Date(),
                note: "Awaiting your reply",
                kind: .droppedBall
            )
            reminders.add(reminder)
            added.append(reminder)
        }
        return added
    }

    /// Surfaces any due, not-yet-fired reminders as notifications and marks
    /// them fired so they don't repeat.
    func fireDueReminders() {
        for reminder in reminders.dueUnfired() {
            let title = reminder.kind == .droppedBall ? "Awaiting your reply" : "Reminder"
            let body = "\(reminder.subject) — \(reminder.from)"
            AppNotificationCenter.shared.post(title: title, message: body, kind: .info)
            reminders.markFired(id: reminder.id)
        }
    }
}
