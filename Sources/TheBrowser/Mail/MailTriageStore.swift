import Combine
import Foundation

/// Owns AI triage: the label definitions, the per-message label assignments,
/// and the user's past corrections (used as few-shot examples so the
/// classifier learns). All local-first under ~/.thebrowser/mail/ — the
/// classification itself happens in `MailAgent`; this store just remembers the
/// inputs and outputs.
@MainActor
final class MailTriageStore: ObservableObject {
    @Published var labels: [AILabel]
    /// messageId → decision. Local source of truth for which AI label a
    /// message carries (mirroring to real Gmail labels is opt-in and handled
    /// elsewhere).
    @Published private(set) var assignments: [String: TriageDecision]
    @Published private(set) var examples: [TriageExample]

    private static let labelsFile = "labels.json"
    private static let assignmentsFile = "triage.json"
    private static let examplesFile = "triage_examples.json"

    init() {
        // Merge persisted labels over the defaults so new built-ins added in
        // later versions show up, while user edits/customs are preserved.
        let stored = MailStorage.load([AILabel].self, from: Self.labelsFile) ?? []
        labels = Self.merge(defaults: AILabel.defaults, stored: stored)

        let storedAssignments = MailStorage.load([TriageDecision].self, from: Self.assignmentsFile) ?? []
        assignments = Dictionary(storedAssignments.map { ($0.messageId, $0) }, uniquingKeysWith: { _, b in b })

        examples = MailStorage.load([TriageExample].self, from: Self.examplesFile) ?? []
    }

    private static func merge(defaults: [AILabel], stored: [AILabel]) -> [AILabel] {
        guard !stored.isEmpty else { return defaults }
        var result = stored
        let storedIDs = Set(stored.map(\.id))
        for def in defaults where !storedIDs.contains(def.id) {
            result.append(def)
        }
        return result
    }

    // MARK: - Labels

    var enabledLabels: [AILabel] { labels.filter(\.enabled) }

    func label(id: String) -> AILabel? { labels.first { $0.id == id } }

    func label(forMessage messageId: String) -> AILabel? {
        guard let decision = assignments[messageId] else { return nil }
        return label(id: decision.labelId)
    }

    func updateLabels(_ newLabels: [AILabel]) {
        labels = newLabels
        persistLabels()
    }

    func setLabel(_ label: AILabel) {
        if let idx = labels.firstIndex(where: { $0.id == label.id }) {
            labels[idx] = label
        } else {
            labels.append(label)
        }
        persistLabels()
    }

    // MARK: - Assignments

    /// Records the classifier's verdicts. Existing assignments for the same
    /// messages are overwritten.
    func apply(_ decisions: [TriageDecision]) {
        guard !decisions.isEmpty else { return }
        for decision in decisions {
            assignments[decision.messageId] = decision
        }
        persistAssignments()
    }

    /// Messages we've already classified — used to skip them on the next
    /// throttled pass so we only spend tokens on genuinely new mail.
    func isClassified(_ messageId: String) -> Bool { assignments[messageId] != nil }

    /// The user corrected a label by hand. Store the new assignment AND keep a
    /// few-shot example so the classifier stops making the same mistake.
    func recordCorrection(
        messageId: String,
        from input: TriageInput,
        toLabelId labelId: String
    ) {
        assignments[messageId] = TriageDecision(messageId: messageId, labelId: labelId, confidence: 1.0)
        persistAssignments()

        let example = TriageExample(
            from: input.from,
            subject: input.subject,
            snippet: input.snippet,
            correctLabelId: labelId
        )
        examples.append(example)
        // Keep the window bounded so the classify prompt stays small.
        if examples.count > 40 {
            examples.removeFirst(examples.count - 40)
        }
        MailStorage.save(examples, to: Self.examplesFile)
    }

    func counts() -> [String: Int] {
        var result: [String: Int] = [:]
        for decision in assignments.values {
            result[decision.labelId, default: 0] += 1
        }
        return result
    }

    // MARK: - Persistence

    private func persistLabels() { MailStorage.save(labels, to: Self.labelsFile) }
    private func persistAssignments() {
        MailStorage.save(Array(assignments.values), to: Self.assignmentsFile)
    }
}
