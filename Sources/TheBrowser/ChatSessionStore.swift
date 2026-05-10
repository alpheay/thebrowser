import Foundation

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
        let dir = Self.rootURL.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
                MessagePayload(role: msg.role.persistedValue, text: msg.text)
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

    func load(sessionID: String) -> [ChatMessage] {
        let file = directory(for: sessionID).appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: file),
              let payload = try? decoder.decode(SessionPayload.self, from: data)
        else { return [] }

        return payload.messages.compactMap { item in
            guard let role = ChatMessage.Role(persistedValue: item.role) else { return nil }
            return ChatMessage(role: role, text: item.text)
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
