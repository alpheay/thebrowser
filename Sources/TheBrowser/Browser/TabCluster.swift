import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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

/// Drag payload — just the source tab's UUID, encoded so SwiftUI's
/// `.draggable` / `.dropDestination` can shuttle it between rows.
struct DraggedTabPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabRailItem)
    }
}

extension UTType {
    /// Private content type for the tab-rail drag — keeps the payload from
    /// being interpreted by other drop targets in the app.
    static let tabRailItem = UTType(exportedAs: "com.thebrowser.tab-rail-item")
}
