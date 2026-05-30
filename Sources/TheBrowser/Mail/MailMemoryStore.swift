import Combine
import Foundation

/// Anchored memories — facts, preferences, and instructions the assistant
/// keeps to personalize drafts and triage. Local-first under
/// ~/.thebrowser/mail/memories.json. Memories are scoped by `anchor`
/// (a specific person, a company domain, an activity, or `always`) so the
/// right context surfaces for the right thread without dumping everything
/// into every prompt.
@MainActor
final class MailMemoryStore: ObservableObject {
    @Published private(set) var memories: [MailMemory]

    private static let file = "memories.json"

    init() {
        memories = MailStorage.load([MailMemory].self, from: Self.file) ?? []
    }

    // MARK: - Mutations

    func add(_ memory: MailMemory) {
        memories.append(memory)
        persist()
    }

    func add(text: String, anchor: MailMemoryAnchor, source: String = "manual", confirmed: Bool = true) {
        add(MailMemory(text: text, anchor: anchor, source: source, confirmed: confirmed))
    }

    func delete(id: UUID) {
        memories.removeAll { $0.id == id }
        persist()
    }

    func confirm(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].confirmed = true
        persist()
    }

    /// Adds auto-extracted candidates, skipping near-duplicates of memories we
    /// already hold (same anchor + very similar text). Returns the ones that
    /// were actually new, so the caller can offer them to the user.
    @discardableResult
    func addCandidates(_ candidates: [MailMemory]) -> [MailMemory] {
        var added: [MailMemory] = []
        for candidate in candidates where !isDuplicate(candidate) {
            memories.append(candidate)
            added.append(candidate)
        }
        if !added.isEmpty { persist() }
        return added
    }

    private func isDuplicate(_ candidate: MailMemory) -> Bool {
        let key = candidate.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return memories.contains { existing in
            existing.anchor == candidate.anchor
                && existing.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key
        }
    }

    // MARK: - Retrieval

    /// Memories relevant to a thread with `contactEmail`: anything anchored to
    /// that person, their domain, the given activities, or marked `always`.
    func relevant(toEmail contactEmail: String?, activities: [String] = []) -> [MailMemory] {
        let email = contactEmail?.lowercased()
        let domain = email?.split(separator: "@").last.map(String.init)
        let activitySet = Set(activities.map { $0.lowercased() })

        return memories.filter { memory in
            switch memory.anchor.kind {
            case .always:
                return true
            case .email:
                return email != nil && memory.anchor.value == email
            case .domain:
                return domain != nil && memory.anchor.value == domain
            case .activity:
                return activitySet.contains(memory.anchor.value)
            }
        }
    }

    /// Substring search across memory text, for the `mail_memory search` tool.
    func search(_ query: String) -> [MailMemory] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return memories }
        return memories.filter { $0.text.lowercased().contains(q) }
    }

    private func persist() { MailStorage.save(memories, to: Self.file) }
}
