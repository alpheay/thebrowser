import Foundation

/// Process-wide in-memory cache for AI search answers.
///
/// `SearchResultsView` is torn down whenever the user navigates away from a
/// search page (to a URL, to home, to another tab where the search slot is
/// occupied by a web view), and a fresh instance — with fresh `@State` — is
/// reinstantiated on back-nav. Reload similarly re-fires the `.task(id:)`.
/// Caching the answer above the view layer is the only way to skip the
/// regenerate cycle in either path.
///
/// Key is the normalized question string, not the `BrowserSearchPage.id`,
/// because each navigation mints a fresh UUID — so a stable answer for
/// "narwhals lifespan" works across tabs and across re-typings.
actor AIAnswerCache {
    static let shared = AIAnswerCache()

    struct Entry: Sendable {
        let answer: String
        /// Citation URLs and titles captured at generation time. We replay
        /// these on cache hit instead of recomputing from the current search
        /// response — the answer's inline `[N]` markers were grounded
        /// against this exact list, so swapping in fresh URLs would
        /// misattribute the references.
        let citationURLs: [URL]
        let citationTitles: [String]
    }

    /// Bounded LRU. Browsing rarely revisits more than a handful of search
    /// pages per session; 64 keeps memory flat without ever evicting an
    /// answer the user is realistically about to want back.
    private let limit = 64
    private var store: [String: Entry] = [:]
    private var order: [String] = []  // oldest first; newest pushed onto end

    func entry(for question: String) -> Entry? {
        let key = Self.normalize(question)
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ entry: Entry, for question: String) {
        let key = Self.normalize(question)
        if store[key] == nil {
            order.append(key)
            while order.count > limit {
                let evicted = order.removeFirst()
                store.removeValue(forKey: evicted)
            }
        } else {
            touch(key)
        }
        store[key] = entry
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }

    private static func normalize(_ question: String) -> String {
        question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
