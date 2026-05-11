import Foundation

/// A named group of tabs in the side rail. Clusters are identified by their
/// normalized host so the "Magnetic" feature can decide whether a sibling
/// tab belongs in the same bucket. The id is what's stored on each tab.
struct TabCluster: Identifiable, Equatable, Hashable {
    let id: UUID
    var host: String
    var name: String
    var isExpanded: Bool

    init(id: UUID = UUID(), host: String, name: String, isExpanded: Bool = true) {
        self.id = id
        self.host = host
        self.name = name
        self.isExpanded = isExpanded
    }
}

extension TabCluster {
    /// Turns a host like `github.com` into a friendly cluster name (`Github`).
    /// We intentionally don't keep a hand-curated mapping — the second-level
    /// label with its first letter capitalized reads clearly for every site
    /// and stays predictable as new domains show up.
    static func displayName(forHost host: String) -> String {
        let parts = host.split(separator: ".", omittingEmptySubsequences: true)
        guard let first = parts.first, !first.isEmpty else {
            return host.isEmpty ? "Group" : host
        }
        let lead = String(first.prefix(1)).uppercased()
        return lead + first.dropFirst()
    }

    /// Strips a `www.` prefix and lowercases. Used for cluster identity so
    /// `www.github.com` and `github.com` merge into the same group.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("www.") {
            return String(lower.dropFirst(4))
        }
        return lower
    }
}

/// Pasteboard type identifier for tab-row drags. We don't promote this to a
/// real `UTType` declaration because the app ships as an SPM executable
/// without an Info.plist — without the plist entry, `UTType(exportedAs:)`
/// is unreliable for `.draggable` / `.dropDestination`. NSItemProvider is
/// happy to ferry arbitrary UTI strings between views in the same process,
/// so we keep the identifier as a plain `String` and use the `.onDrag` /
/// `.onDrop` SwiftUI APIs directly.
enum TabDragType {
    static let identifier = "com.thebrowser.tab-rail-item"
}
