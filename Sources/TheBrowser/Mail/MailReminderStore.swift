import Combine
import Foundation

/// The follow-up safety net: manual reminders ("remind me Friday") plus
/// dropped-ball nudges the scanner infers for threads awaiting the user's
/// reply. Local-first under ~/.thebrowser/mail/reminders.json. Due reminders
/// surface through `AppNotificationCenter`; replying to or archiving a thread
/// auto-dismisses its reminder.
@MainActor
final class MailReminderStore: ObservableObject {
    @Published private(set) var reminders: [MailReminder]

    private static let file = "reminders.json"

    init() {
        reminders = MailStorage.load([MailReminder].self, from: Self.file) ?? []
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ reminder: MailReminder) -> MailReminder {
        // One reminder per thread — a new one supersedes the old.
        reminders.removeAll { $0.threadId == reminder.threadId }
        reminders.append(reminder)
        persist()
        return reminder
    }

    func remove(id: UUID) {
        reminders.removeAll { $0.id == id }
        persist()
    }

    /// Removes any reminder tied to a thread — called when the user replies to
    /// or archives it, so resolved threads stop nudging.
    func dismissThread(_ threadId: String) {
        let before = reminders.count
        reminders.removeAll { $0.threadId == threadId }
        if reminders.count != before { persist() }
    }

    func hasReminder(threadId: String) -> Bool {
        reminders.contains { $0.threadId == threadId }
    }

    func markFired(id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].firedAt = Date()
        persist()
    }

    // MARK: - Queries

    /// Reminders that are due and haven't been surfaced yet.
    func dueUnfired(now: Date = Date()) -> [MailReminder] {
        reminders.filter { $0.dueAt <= now && $0.firedAt == nil }
    }

    /// Thread ids that currently carry a reminder, for the overlay's
    /// "Needs reply" filter and row badges.
    var reminderThreadIDs: Set<String> { Set(reminders.map(\.threadId)) }

    private func persist() { MailStorage.save(reminders, to: Self.file) }
}
