import Combine
import Foundation

/// Single source of truth for the bookmarks UI. Owns the in-memory list
/// (mirrored from ``BookmarksStore``), the auto-tagging queue, and the
/// migration backfill state.
///
/// The manager is a long-lived singleton. UI views observe it directly
/// via `@ObservedObject` / `@StateObject`. Persistence lives in
/// ``BookmarksStore``; the manager handles policy + AI orchestration.
@MainActor
final class BookmarksManager: ObservableObject {
    static let shared = BookmarksManager()

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var taggingInProgress: Set<String> = []
    @Published private(set) var migrationBackfill: MigrationBackfillState = .idle

    struct MigrationBackfillState: Equatable {
        var isRunning: Bool
        var total: Int
        var completed: Int

        static let idle = MigrationBackfillState(isRunning: false, total: 0, completed: 0)

        var progressLabel: String {
            "Tagging your bookmarks: \(completed)/\(total)…"
        }
    }

    private let store: BookmarksStore

    /// Max concurrent CLI calls. Keeps Claude/Codex from getting hammered
    /// during a 2,000-row migration backfill.
    private let maxConcurrentTags = 5

    private init() {
        self.store = BookmarksStore.shared
        self.bookmarks = store.listBookmarks()

        // Singleton — no deinit cleanup needed. Observer is held by
        // `NotificationCenter` for the app's lifetime.
        NotificationCenter.default.addObserver(
            forName: BookmarksStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    // MARK: - List queries

    /// Re-pulls the store's row set. Cheap — bookmark count rarely exceeds
    /// low thousands and the SQL is already indexed by `created_at_iso`.
    func refresh() {
        let fresh = store.listBookmarks()
        // Preserve the transient `isTagging` flag for rows currently being
        // worked on; SQLite reads always set it to false.
        let active = taggingInProgress
        bookmarks = fresh.map { row in
            var copy = row
            if active.contains(row.id) {
                copy.isTagging = true
            }
            return copy
        }
    }

    func bookmarks(in folder: String) -> [Bookmark] {
        bookmarks.filter { $0.folder == folder }
    }

    func search(query: String, tags: [String]) -> [Bookmark] {
        let rows = store.searchBookmarks(query: query, tags: tags)
        let active = taggingInProgress
        return rows.map { row in
            var copy = row
            if active.contains(row.id) {
                copy.isTagging = true
            }
            return copy
        }
    }

    func isBookmarked(url: String) -> Bool {
        store.isBookmarked(url: url)
    }

    func bookmark(forURL url: String) -> Bookmark? {
        store.bookmark(forURL: url)
    }

    func allTags() -> [String] {
        store.allTags()
    }

    func allFolders() -> [String] {
        store.allFolders()
    }

    // MARK: - CRUD

    /// Adds the current page as a bookmark. Returns the saved row, or nil
    /// if the URL is empty / a duplicate. Kicks off auto-tagging in the
    /// background when auto-tagging is enabled and an excerpt is
    /// available; UI presents the "tagging…" spinner via ``taggingInProgress``.
    @discardableResult
    func addBookmark(
        url: String,
        title: String,
        folder: String = BookmarkFolders.root,
        excerpt: String? = nil
    ) -> Bookmark? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        if let existing = store.bookmark(forURL: trimmedURL) {
            return existing
        }

        let bookmark = Bookmark(
            id: UUID().uuidString,
            url: trimmedURL,
            title: title,
            faviconPath: "",
            folder: folder,
            createdAt: Date(),
            tags: [],
            descriptionText: "",
            isTagging: false
        )
        guard store.addBookmark(bookmark) else { return nil }

        if autoTaggingEnabled {
            scheduleTagging(id: bookmark.id, title: title, url: trimmedURL, excerpt: excerpt)
        }
        return bookmark
    }

    func removeBookmark(id: String) {
        store.removeBookmark(id: id)
    }

    func removeBookmark(url: String) {
        store.removeBookmark(url: url)
    }

    func updateBookmark(
        id: String,
        title: String? = nil,
        folder: String? = nil,
        tags: [String]? = nil,
        descriptionText: String? = nil
    ) {
        store.updateBookmark(
            id: id,
            title: title,
            folder: folder,
            tags: tags,
            descriptionText: descriptionText
        )
    }

    // MARK: - AI tagging

    /// Single-bookmark tag refresh. Runs whether or not auto-tagging is
    /// the saved default — callers are explicit ("Re-tag" button, fresh
    /// add when enabled). Silent on failure.
    func scheduleTagging(id: String, title: String, url: String, excerpt: String? = nil) {
        guard !taggingInProgress.contains(id) else { return }
        taggingInProgress.insert(id)
        // Reflect the spinner immediately in the local list.
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].isTagging = true
        }

        let model = taggingModelOverride
        Task { @MainActor [weak self] in
            defer {
                self?.taggingInProgress.remove(id)
                if let index = self?.bookmarks.firstIndex(where: { $0.id == id }) {
                    self?.bookmarks[index].isTagging = false
                }
            }
            do {
                let result = try await BookmarksAITagger.tag(
                    title: title,
                    url: url,
                    excerpt: excerpt,
                    modelOverride: model
                )
                guard !result.tags.isEmpty || !result.descriptionText.isEmpty else { return }
                self?.store.updateBookmark(
                    id: id,
                    tags: result.tags,
                    descriptionText: result.descriptionText
                )
            } catch {
                // Failures are silent by design — bookmark is still saved.
            }
        }
    }

    /// "Re-tag all bookmarks" entrypoint. Clears every row's existing
    /// tags + description then re-runs the migration backfill so the new
    /// model picks them all up.
    func retagAll() {
        store.clearAllAITags()
        // Force the backfill to re-run regardless of the migration flag.
        UserDefaults.standard.set(false, forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
        runMigrationBackfillIfNeeded()
    }

    // MARK: - Migration backfill

    /// Called on app launch (and after each Migration import) to enqueue
    /// any bookmarks that haven't yet been seen by the AI tagger. Idempotent
    /// per-row: rows that already have tags or description are skipped.
    /// Sets ``bookmarksAutoTagMigrationCompletedV1`` once it has nothing
    /// more to do.
    func runMigrationBackfillIfNeeded() {
        guard autoTaggingEnabled else { return }
        guard !migrationBackfill.isRunning else { return }

        // Pull every untagged row. If the user starred a brand-new
        // bookmark *after* a finished backfill, this picks it up too —
        // we always do a sweep even if the v1 flag is already set,
        // because the cost of a no-op pass is one SQL query.
        let pending = store.listUntaggedBookmarks()
        guard !pending.isEmpty else {
            UserDefaults.standard.set(true, forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
            return
        }

        // Don't run the full backfill on every launch — only when the
        // v1 flag is unset (fresh install / fresh migration) or when
        // `retagAll()` explicitly cleared it.
        let flagSet = UserDefaults.standard.bool(forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
        guard !flagSet else { return }

        migrationBackfill = MigrationBackfillState(
            isRunning: true,
            total: pending.count,
            completed: 0
        )

        // Kick off a bounded worker pool. Each task pulls from `pending`
        // by index; we stop scheduling new ones when the queue is empty.
        Task { @MainActor in
            await processBackfill(rows: pending)
        }
    }

    /// Internal: walks `rows` in chunks of ``maxConcurrentTags`` so the
    /// underlying CLI never sees more than that many concurrent calls.
    /// Each chunk fans out via async-let, then the next chunk waits for
    /// it to drain. Simpler than a TaskGroup, and the per-row CLI call
    /// dominates wall time so the extra serialization between chunks is
    /// invisible.
    private func processBackfill(rows: [Bookmark]) async {
        let provider = AIHarnessConfiguration.current().provider
        let model = taggingModelOverride.flatMap { $0.isEmpty ? nil : $0 } ?? provider.fastModelID
        let concurrency = max(1, maxConcurrentTags)

        var index = 0
        while index < rows.count {
            let end = min(index + concurrency, rows.count)
            let batch = Array(rows[index..<end])
            await processBackfillChunk(batch, model: model)
            migrationBackfill.completed = end
            index = end
        }

        migrationBackfill = .idle
        UserDefaults.standard.set(true, forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
    }

    /// Runs up to ``maxConcurrentTags`` tagging calls in parallel using
    /// async-let. Each step's outcome is applied to the store inline so
    /// the UI's "tagging…" spinner clears as soon as the response lands.
    private func processBackfillChunk(_ rows: [Bookmark], model: String) async {
        await withTaskGroup(of: TaggingOutcome.self) { group in
            for row in rows {
                group.addTask {
                    do {
                        let result = try await BookmarksAITagger.tag(
                            title: row.title,
                            url: row.url,
                            excerpt: nil,
                            modelOverride: model
                        )
                        return TaggingOutcome(id: row.id, result: result)
                    } catch {
                        return TaggingOutcome(id: row.id, result: nil)
                    }
                }
            }
            for await outcome in group {
                if let result = outcome.result,
                   (!result.tags.isEmpty || !result.descriptionText.isEmpty) {
                    store.updateBookmark(
                        id: outcome.id,
                        tags: result.tags,
                        descriptionText: result.descriptionText
                    )
                }
            }
        }
    }

    private struct TaggingOutcome: Sendable {
        var id: String
        var result: BookmarksAITagger.Result?
    }

    // MARK: - Migration intake

    /// Ingests the `ImportedBookmark` set from the Migration module. New
    /// rows are inserted (duplicates by URL skipped); the backfill is then
    /// kicked off so the freshly-imported rows get tagged. This is wired
    /// into ``BrowserMigrationService.migrate`` so any re-run picks up
    /// only the new rows.
    func ingestMigratedBookmarks(_ imported: [ImportedBookmark]) {
        for entry in imported {
            let bookmark = Bookmark(
                id: UUID().uuidString,
                url: entry.url,
                title: entry.title,
                faviconPath: "",
                folder: BookmarkFolders.imported,
                createdAt: Date(),
                tags: [],
                descriptionText: "",
                isTagging: false
            )
            store.addBookmark(bookmark)
        }
        // Each migration run reopens the door to backfill — even if the
        // v1 flag is already set, the newly-imported rows are untagged
        // so they should run.
        if store.listUntaggedBookmarks().isEmpty == false {
            UserDefaults.standard.set(false, forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
        }
        runMigrationBackfillIfNeeded()
    }

    /// Existing rows already on disk from a prior migration import. Read
    /// from the Migration's UserDefaults snapshot and merged into the
    /// store. Idempotent: duplicate URLs are skipped at the SQLite layer.
    /// If any of those rows land untagged, the v1 flag is cleared so the
    /// backfill picks them up — covers the "user upgraded to this build
    /// after a previous migration" path.
    func importExistingMigratedBookmarksIfNeeded() {
        let existing = MigrationImportStore.importedBookmarks(limit: 2_000)
        for entry in existing {
            let bookmark = Bookmark(
                id: UUID().uuidString,
                url: entry.url,
                title: entry.title,
                faviconPath: "",
                folder: BookmarkFolders.imported,
                createdAt: Date(),
                tags: [],
                descriptionText: "",
                isTagging: false
            )
            store.addBookmark(bookmark)
        }
        if !store.listUntaggedBookmarks().isEmpty {
            UserDefaults.standard.set(false, forKey: PreferenceKey.bookmarksAutoTagMigrationCompletedV1)
        }
        runMigrationBackfillIfNeeded()
    }

    // MARK: - Settings-backed prefs

    var autoTaggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.bookmarksAutoTagEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.bookmarksAutoTagEnabled) }
    }

    /// Empty string means "use the provider's fast model".
    var taggingModelOverride: String? {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.bookmarksTaggingModel) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
