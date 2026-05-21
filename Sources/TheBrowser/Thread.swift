import Foundation
import SwiftData

struct TabSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var url: URL?
    var title: String
    var interactionState: Data?
    var lastScreenshotPath: String?
    var lastVisitedAt: Date

    init(
        id: UUID = UUID(),
        url: URL?,
        title: String,
        interactionState: Data? = nil,
        lastScreenshotPath: String? = nil,
        lastVisitedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.interactionState = interactionState
        self.lastScreenshotPath = lastScreenshotPath
        self.lastVisitedAt = lastVisitedAt
    }
}

struct ThreadAgentContext: Codable, Equatable, Sendable {
    var sessionID: String

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    init?(serialized: String) {
        let trimmed = serialized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ThreadAgentContext.self, from: data),
           !decoded.sessionID.isEmpty {
            self = decoded
        } else {
            // Sessions created before Thread agent context existed were
            // represented by the bare chat session id.
            self.sessionID = trimmed
        }
    }

    var serialized: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return sessionID
        }
        return value
    }
}

enum ThreadScratchDirectory {
    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
    }()

    static func url(for id: UUID) -> URL {
        rootURL
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("scratch", isDirectory: true)
    }
}

struct ThreadRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var lastFocusedAt: Date
    var tabs: [TabSnapshot]
    var agentContext: String
    var scratchDirPath: String
    var isArchived: Bool
    var isWindowOpen: Bool

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        lastFocusedAt: Date,
        tabs: [TabSnapshot],
        agentContext: String,
        scratchDirPath: String,
        isArchived: Bool,
        isWindowOpen: Bool
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastFocusedAt = lastFocusedAt
        self.tabs = tabs
        self.agentContext = agentContext
        self.scratchDirPath = scratchDirPath
        self.isArchived = isArchived
        self.isWindowOpen = isWindowOpen
    }

    init(thread: Thread) {
        self.id = thread.id
        self.title = thread.title
        self.createdAt = thread.createdAt
        self.lastFocusedAt = thread.lastFocusedAt
        self.tabs = thread.tabs
        self.agentContext = thread.agentContext
        self.scratchDirPath = thread.scratchDirPath
        self.isArchived = thread.isArchived
        self.isWindowOpen = thread.isWindowOpen
    }
}

@Model
final class Thread {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var lastFocusedAt: Date
    var tabs: [TabSnapshot]
    var agentContext: String
    var scratchDirPath: String
    var isArchived: Bool
    var isWindowOpen: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Thread",
        createdAt: Date = Date(),
        lastFocusedAt: Date = Date(),
        tabs: [TabSnapshot] = [],
        agentContext: String = "",
        scratchDirPath: String? = nil,
        isArchived: Bool = false,
        isWindowOpen: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastFocusedAt = lastFocusedAt
        self.tabs = tabs
        self.agentContext = agentContext
        self.scratchDirPath = scratchDirPath ?? ThreadScratchDirectory.url(for: id).path
        self.isArchived = isArchived
        self.isWindowOpen = isWindowOpen
    }
}

extension Thread {
    static func generatedTitle(from tabs: [TabSnapshot], fallback: String = "New Thread") -> String {
        for tab in tabs {
            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title != "New Space" {
                return title
            }

            if let host = tab.url?.host(percentEncoded: false), !host.isEmpty {
                return host
            }
        }

        return fallback
    }
}
