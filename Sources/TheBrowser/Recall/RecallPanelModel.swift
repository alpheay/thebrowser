import Combine
import Foundation

/// Drives the instant-recall command bar: debounced local search, keyboard
/// selection, and starring. Pure retrieval — no network, no cloud model — so
/// this surface answers "where did I read that" with zero data leaving the Mac.
/// The optional synthesized answer (zero-egress, on-device) is filled by
/// ``RecallAnswerEngine`` when local-answer mode is on.
@MainActor
final class RecallPanelModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [RecallHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var didSearch = false
    @Published var selectedIndex = 0
    @Published private(set) var answer: RecallAnswer?
    @Published private(set) var isAnswering = false
    /// Pages related to the one the user is currently viewing — proactive
    /// "you've read about this before" connections, shown before they type.
    @Published private(set) var related: [RecallDocument] = []

    private var searchTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var relatedTask: Task<Void, Never>?

    /// Debounce so each keystroke doesn't fire a query; 180ms feels instant
    /// while collapsing a burst of typing into one search.
    private static let debounceNanos: UInt64 = 180_000_000

    func reset() {
        searchTask?.cancel()
        answerTask?.cancel()
        relatedTask?.cancel()
        query = ""
        results = []
        answer = nil
        related = []
        selectedIndex = 0
        didSearch = false
        isSearching = false
        isAnswering = false
    }

    /// Loads pages semantically related to the one being viewed, for the
    /// idle state. Quietly no-ops when semantic search is off or there's no
    /// page in focus.
    func loadRelated(to url: URL?) {
        relatedTask?.cancel()
        guard let url else { related = []; return }
        relatedTask = Task { [weak self] in
            let docs = await RecallController.shared.relatedDocuments(to: url, limit: 4)
            guard !Task.isCancelled, let self else { return }
            self.related = docs
        }
    }

    func onQueryChange() {
        searchTask?.cancel()
        answerTask?.cancel()
        answer = nil
        isAnswering = false

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            didSearch = false
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled, let self else { return }
            let hits = await RecallController.shared.search(trimmed, limit: 12)
            guard !Task.isCancelled else { return }
            self.results = hits
            self.selectedIndex = 0
            self.isSearching = false
            self.didSearch = true
            if RecallController.shared.localAnswerMode, !hits.isEmpty {
                self.synthesizeAnswer(query: trimmed, hits: hits)
            }
        }
    }

    /// On-device extractive answer over the top passages — runs only in
    /// local-answer mode, so nothing is sent anywhere.
    private func synthesizeAnswer(query: String, hits: [RecallHit]) {
        isAnswering = true
        answerTask = Task { [weak self] in
            let synthesized = RecallAnswerEngine.answer(query: query, hits: hits)
            guard !Task.isCancelled, let self else { return }
            self.answer = synthesized
            self.isAnswering = false
        }
    }

    // MARK: - Selection

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    var selectedHit: RecallHit? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    // MARK: - Star

    func toggleStar(_ hit: RecallHit) {
        let newValue = !hit.starred
        RecallController.shared.setStarred(hit.url, starred: newValue)
        if let index = results.firstIndex(where: { $0.id == hit.id }) {
            results[index].starred = newValue
        }
    }
}
