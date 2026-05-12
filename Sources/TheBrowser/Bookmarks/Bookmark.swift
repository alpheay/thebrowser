import Foundation

/// A user-visible bookmark. Persisted by ``BookmarksStore``. Tags and
/// description are populated asynchronously by the Smart Bookmarks
/// auto-tagging pipeline; an empty ``tags`` array means "not yet tagged"
/// when ``descriptionText`` is also empty.
struct Bookmark: Identifiable, Hashable, Sendable {
    var id: String
    var url: String
    var title: String
    var faviconPath: String
    var folder: String
    var createdAt: Date
    var tags: [String]
    var descriptionText: String
    /// True while the auto-tagging pipeline is enriching this row. UI uses
    /// this to draw the subtle "tagging…" spinner. Not persisted to SQLite —
    /// it always resets to false on launch.
    var isTagging: Bool = false

    /// Convenience: a row that has been through the AI pipeline at least
    /// once and has either tags or a description. Used by the migration
    /// backfill to decide which rows to enqueue.
    var hasAITags: Bool {
        !tags.isEmpty || !descriptionText.isEmpty
    }

    var host: String {
        URL(string: url)?.host(percentEncoded: false) ?? ""
    }
}

/// Top-level folder identifier shared between the bookmark bar, the
/// sidebar tree, and the SQLite column. Migration imports default to
/// ``imported``; bookmarks added via ⌥⌘D land in ``root``.
enum BookmarkFolders {
    static let root = ""
    static let imported = "Imported"
}
