import Foundation

/// Lightweight metadata describing a persisted chat session — enough to render
/// a row in the session-history picker without loading the full message list.
struct SessionSummary: Identifiable, Equatable {
    let id: String
    let updatedAt: Date
    let pageTitle: String
    let firstUserMessage: String?
    let messageCount: Int
}

/// Persists chat sessions under ``~/.thebrowser/sessions/<id>/messages.json`` and
/// vends each session's directory as a working directory for the underlying CLI
/// (codex / claude). Each session has its own isolated directory so the CLI
/// can't see (or pollute) the user's other projects.
@MainActor
final class ChatSessionStore {
    static let shared = ChatSessionStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }()

    /// Override the sessions root for tests; production code uses `rootURL`.
    private let root: URL

    init(root: URL = ChatSessionStore.rootURL) {
        self.root = root
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Session lifecycle

    /// Creates a new session directory on disk and returns its ID.
    func newSessionID() -> String {
        let id = Self.makeID()
        ensureDirectory(for: id)
        return id
    }

    /// Returns the absolute directory URL for the given session, creating it on
    /// demand.
    @discardableResult
    func directory(for sessionID: String) -> URL {
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes a single session's directory (and the `messages.json` inside)
    /// from disk. No-op if the directory doesn't exist.
    func delete(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        let dir = root.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes every persisted session under the root. The root directory
    /// itself is preserved so subsequent `directory(for:)` calls keep working.
    func clearAll() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectory(for sessionID: String) {
        _ = directory(for: sessionID)
    }

    private static func makeID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(stamp)_\(suffix)"
    }

    // MARK: - Persistence

    func save(messages: [ChatMessage], sessionID: String, pageContext: BrowserPageContext) {
        guard !sessionID.isEmpty else { return }
        let file = directory(for: sessionID).appendingPathComponent("messages.json")

        let payload = SessionPayload(
            id: sessionID,
            updatedAt: Date(),
            pageTitle: pageContext.title,
            pageURL: pageContext.url,
            messages: messages.map { msg in
                MessagePayload(
                    role: msg.role.persistedValue,
                    text: msg.text,
                    toolChain: msg.toolChain.isEmpty
                        ? nil
                        : msg.toolChain.map {
                            ToolInvocationPayload(
                                tool: $0.tool,
                                input: $0.input,
                                succeeded: $0.succeeded,
                                artifactURL: $0.artifactURL?.absoluteString
                            )
                        }
                )
            }
        )

        do {
            let data = try encoder.encode(payload)
            try data.write(to: file, options: .atomic)
        } catch {
            // Persistence is best-effort; the chat still works in memory.
            #if DEBUG
            print("ChatSessionStore: failed to save \(sessionID): \(error)")
            #endif
        }
    }

    /// Enumerates every persisted session, newest first. Skips entries whose
    /// `messages.json` is missing, unreadable, or contains zero messages —
    /// these surface as either fresh-but-untouched sessions or partial writes
    /// that shouldn't appear in the picker.
    func listSessions() -> [SessionSummary] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(entries.count)

        for dir in entries {
            let isDirectory = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }

            let file = dir.appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: file),
                  let payload = try? decoder.decode(SessionPayload.self, from: data),
                  !payload.messages.isEmpty
            else { continue }

            let firstUser = payload.messages.first(where: { $0.role == "user" })?.text
            summaries.append(SessionSummary(
                id: payload.id,
                updatedAt: payload.updatedAt,
                pageTitle: payload.pageTitle,
                firstUserMessage: firstUser,
                messageCount: payload.messages.count
            ))
        }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(sessionID: String) -> [ChatMessage] {
        let file = directory(for: sessionID).appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: file),
              let payload = try? decoder.decode(SessionPayload.self, from: data)
        else { return [] }

        return payload.messages.compactMap { item in
            guard let role = ChatMessage.Role(persistedValue: item.role) else { return nil }
            let chain = (item.toolChain ?? []).map {
                ChatMessage.ToolInvocation(
                    tool: $0.tool,
                    input: $0.input,
                    succeeded: $0.succeeded,
                    artifactURL: $0.artifactURL.flatMap(URL.init(string:))
                )
            }
            return ChatMessage(role: role, text: item.text, toolChain: chain)
        }
    }

    // MARK: - Codable payloads

    private struct SessionPayload: Codable {
        var id: String
        var updatedAt: Date
        var pageTitle: String
        var pageURL: String
        var messages: [MessagePayload]
    }

    private struct MessagePayload: Codable {
        var role: String
        var text: String
        var toolChain: [ToolInvocationPayload]?
    }

    private struct ToolInvocationPayload: Codable {
        var tool: String
        var input: String
        var succeeded: Bool
        var artifactURL: String?
    }
}

extension ChatMessage.Role {
    var persistedValue: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "system": self = .system
        default: return nil
        }
    }
}
