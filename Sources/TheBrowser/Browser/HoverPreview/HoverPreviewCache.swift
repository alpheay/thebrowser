import Foundation

/// One cached preview. Both fields are independently nilable so a prefetch
/// can land before the summary completes and we still serve a useful
/// partial card.
struct HoverPreviewCacheEntry: Equatable {
    var content: HoverPreviewContent
    var summary: String?

    init(content: HoverPreviewContent, summary: String? = nil) {
        self.content = content
        self.summary = summary
    }
}

/// LRU cache, capacity 50 by default. Session-only — held by the shell-level
/// ``HoverPreviewModel`` and dropped when the app exits. Keyed by absolute
/// URL string (we strip the URL's fragment before keying so #section
/// variants share a body).
@MainActor
final class HoverPreviewCache {
    private struct Node {
        var entry: HoverPreviewCacheEntry
    }

    private var storage: [String: Node] = [:]
    private var recency: [String] = [] // most-recent last

    let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func contains(_ url: URL) -> Bool {
        storage[Self.key(for: url)] != nil
    }

    func value(for url: URL) -> HoverPreviewCacheEntry? {
        let key = Self.key(for: url)
        guard let node = storage[key] else { return nil }
        bump(key: key)
        return node.entry
    }

    func setContent(_ content: HoverPreviewContent, for url: URL) {
        let key = Self.key(for: url)
        if var existing = storage[key] {
            existing.entry.content = content
            storage[key] = existing
            bump(key: key)
            return
        }
        storage[key] = Node(entry: HoverPreviewCacheEntry(content: content))
        recency.append(key)
        evictIfNeeded()
    }

    func setSummary(_ summary: String, for url: URL) {
        let key = Self.key(for: url)
        guard var node = storage[key] else { return }
        node.entry.summary = summary
        storage[key] = node
        bump(key: key)
    }

    func clear() {
        storage.removeAll()
        recency.removeAll()
    }

    private func bump(key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while recency.count > capacity {
            let oldest = recency.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private static func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}
