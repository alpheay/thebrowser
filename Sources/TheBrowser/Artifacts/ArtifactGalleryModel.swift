import Foundation

/// Backing state for the artifact gallery — the full collection plus the
/// active search/date filters. Owned as a single `@StateObject` by the shell
/// so the home-page strip and the full modal share one source of truth (and
/// one thumbnail cache). Refreshing is driven externally via ``reload()`` on
/// `ArtifactStore.didChangeNotification`, mirroring how the history modal
/// reacts to `HistoryStore.didChangeNotification`.
@MainActor
final class ArtifactGalleryModel: ObservableObject {
    @Published private(set) var artifacts: [ArtifactMetadata] = []
    @Published private(set) var isLoaded = false
    @Published var searchQuery: String = ""
    @Published var selectedGroup: HistoryDateGroup = .today

    /// Shared, so a thumbnail rendered for the home strip is reused by the
    /// modal and vice-versa.
    let thumbnails = ArtifactThumbnailRenderer()

    private let store: ArtifactStore

    init(store: ArtifactStore = .shared) {
        self.store = store
    }

    /// Re-scans the artifacts directory and joins each file with the chat
    /// session that produced it. Cheap enough to call on every change.
    func reload() {
        let index = ChatSessionStore.shared.artifactSessionIndex()
        artifacts = store.enumerate().map { meta in
            var resolved = meta
            resolved.session = index[meta.id]
            return resolved
        }
        if !isLoaded {
            // Land on the most recent populated span so a fresh open doesn't
            // show an empty "Today" while older work sits one pill away.
            selectedGroup = mostRecentPopulatedGroup() ?? .today
        }
        isLoaded = true
    }

    // MARK: - Derived

    var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Artifacts to render. A non-empty query searches the whole collection
    /// (the date filter is ignored); otherwise the selected date group narrows
    /// it — the same behavior as `HistoryModalView.filteredEntries`.
    var filteredArtifacts: [ArtifactMetadata] {
        if !trimmedQuery.isEmpty {
            let lower = trimmedQuery.lowercased()
            return artifacts.filter { artifact in
                artifact.title.lowercased().contains(lower)
                    || artifact.fileName.lowercased().contains(lower)
                    || (artifact.session?.pageTitle.lowercased().contains(lower) ?? false)
            }
        }
        return artifacts.filter { selectedGroup.contains($0.createdAt) }
    }

    var countByGroup: [HistoryDateGroup: Int] {
        var counts: [HistoryDateGroup: Int] = [:]
        let now = Date()
        for artifact in artifacts {
            for group in HistoryDateGroup.allCases where group.contains(artifact.createdAt, now: now) {
                counts[group, default: 0] += 1
                break
            }
        }
        return counts
    }

    private func mostRecentPopulatedGroup() -> HistoryDateGroup? {
        let now = Date()
        for group in HistoryDateGroup.allCases
        where artifacts.contains(where: { group.contains($0.createdAt, now: now) }) {
            return group
        }
        return nil
    }
}
