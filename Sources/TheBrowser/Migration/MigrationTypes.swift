import Foundation
import SwiftUI

enum MigrationSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case chrome
    case firefox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }

    var subtitle: String {
        switch self {
        case .chrome: "Google profiles, bookmarks, and history."
        case .firefox: "Mozilla profiles, bookmarks, and history."
        }
    }

    var symbolName: String {
        switch self {
        case .chrome: "globe"
        case .firefox: "flame"
        }
    }
}

enum MigrationDataKind: String, CaseIterable, Identifiable, Sendable {
    case bookmarks
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        }
    }

    var symbolName: String {
        switch self {
        case .bookmarks: "bookmark.fill"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct BrowserProfile: Identifiable, Hashable, Sendable {
    var source: MigrationSource
    var name: String
    var path: URL

    var id: String { "\(source.rawValue):\(path.path)" }

    var detail: String {
        path.lastPathComponent
    }
}

struct ImportedBookmark: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: String

    var id: String { url }
}

struct ImportedHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: String
    var visitCount: Int
    var lastVisitedAt: Date?

    var id: String { url }
}

struct BrowserMigrationPayload: Sendable {
    var bookmarks: [ImportedBookmark] = []
    var history: [ImportedHistoryEntry] = []
    var warnings: [String] = []
}

struct MigrationCounts: Codable, Equatable, Sendable {
    var bookmarks: Int = 0
    var history: Int = 0
}

struct MigrationResult: Codable, Equatable, Sendable {
    var source: MigrationSource
    var profileName: String
    var counts: MigrationCounts
    var warnings: [String]
    var completedAt: Date
}
