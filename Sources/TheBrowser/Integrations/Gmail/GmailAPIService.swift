import Foundation

enum GmailAPIError: LocalizedError {
    case notAuthenticated
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to Gmail first."
        case .http(let code, let body):
            return "Gmail API returned \(code): \(body)"
        case .decoding(let message):
            return "Gmail API response didn't parse: \(message)"
        }
    }
}

/// Thin wrapper over the Gmail REST API. Stateless on its own — the caller
/// (``GmailStore``) supplies the access token and decides how often to
/// refresh. Anything not strictly needed by the integration UI is left out.
struct GmailAPIService {
    let accessToken: String
    let urlSession: URLSession

    init(accessToken: String, urlSession: URLSession = .shared) {
        self.accessToken = accessToken
        self.urlSession = urlSession
    }

    // MARK: - List

    struct ListResult {
        let summaries: [GmailMessageSummary]
        let nextPageToken: String?
    }

    /// Lists message IDs in `mailbox`, then fetches each one with
    /// `format=metadata` (no body) so we can render the inbox list quickly.
    /// `query` runs through Gmail's `q` parameter — same syntax as the
    /// search bar in Gmail itself.
    func listMessages(
        mailbox: GmailMailbox,
        query: String? = nil,
        maxResults: Int = 25,
        pageToken: String? = nil
    ) async throws -> ListResult {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if let label = mailbox.labelID {
            items.append(URLQueryItem(name: "labelIds", value: label))
        }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items

        struct ListResponse: Decodable {
            struct Ref: Decodable {
                let id: String
                let threadId: String
            }
            let messages: [Ref]?
            let nextPageToken: String?
        }
        let list: ListResponse = try await get(components.url!)
        guard let refs = list.messages, !refs.isEmpty else {
            return ListResult(summaries: [], nextPageToken: list.nextPageToken)
        }

        let summaries = try await withThrowingTaskGroup(of: GmailMessageSummary?.self) { group in
            for ref in refs {
                group.addTask { try await self.fetchSummary(id: ref.id) }
            }
            var collected: [GmailMessageSummary] = []
            collected.reserveCapacity(refs.count)
            for try await maybe in group {
                if let summary = maybe { collected.append(summary) }
            }
            // Stable order: newest first (matches `messages.list` ordering).
            let ordering = Dictionary(uniqueKeysWithValues: refs.enumerated().map { ($1.id, $0) })
            collected.sort { (ordering[$0.id] ?? Int.max) < (ordering[$1.id] ?? Int.max) }
            return collected
        }

        return ListResult(summaries: summaries, nextPageToken: list.nextPageToken)
    }

    private func fetchSummary(id: String) async throws -> GmailMessageSummary? {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")!
        let envelope: RawMessage = try await get(url)
        return envelope.toSummary()
    }

    // MARK: - Get full

    func fetchMessage(id: String) async throws -> GmailMessage {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let envelope: RawMessage = try await get(url)
        return envelope.toFullMessage()
    }

    func fetchThread(id: String) async throws -> [GmailMessage] {
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(safeID)?format=full")!
        let envelope: RawThread = try await get(url)
        return envelope.messages
            .map { $0.toFullMessage() }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Send

    /// Sends `draft` as a brand-new message. If `draft.inReplyTo` is set we
    /// thread the reply correctly by including `In-Reply-To` / `References`
    /// headers and pinning `threadId`.
    @discardableResult
    func send(draft: GmailPaneMode.Draft, from: String) async throws -> String {
        let mime = buildMIME(draft: draft, from: from)
        let raw = Data(mime.utf8).base64URLEncodedString()

        var body: [String: Any] = ["raw": raw]
        if let reply = draft.inReplyTo {
            body["threadId"] = reply.threadId
        }

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailAPIError.http((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        struct SendResponse: Decodable { let id: String }
        let decoded = try JSONDecoder().decode(SendResponse.self, from: data)
        return decoded.id
    }

    // MARK: - Label toggles

    @discardableResult
    func modifyLabels(messageID: String, add: [String] = [], remove: [String] = []) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)/modify")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "addLabelIds": add,
            "removeLabelIds": remove
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailAPIError.http((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        return true
    }

    // MARK: - Building blocks

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailAPIError.http((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailAPIError.decoding(error.localizedDescription)
        }
    }

    private func buildMIME(draft: GmailPaneMode.Draft, from: String) -> String {
        var headers: [(String, String)] = [
            ("From", from),
            ("To", draft.to),
            ("Subject", draft.subject),
            ("MIME-Version", "1.0"),
            ("Content-Type", "text/plain; charset=UTF-8")
        ]
        if let reply = draft.inReplyTo {
            headers.append(("In-Reply-To", "<\(reply.id)@mail.gmail.com>"))
            headers.append(("References", "<\(reply.id)@mail.gmail.com>"))
        }
        let headerBlock = headers
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\r\n")
        return headerBlock + "\r\n\r\n" + draft.body
    }
}

// MARK: - Wire types

private struct RawThread: Decodable {
    let id: String
    let messages: [RawMessage]
}

/// Raw shape of `users.messages.get`. We model just the fields we read.
private struct RawMessage: Decodable {
    let id: String
    let threadId: String
    let snippet: String?
    let labelIds: [String]?
    let internalDate: String?
    let payload: Payload?

    struct Payload: Decodable {
        let mimeType: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Payload]?
    }
    struct Header: Decodable {
        let name: String
        let value: String
    }
    struct Body: Decodable {
        let data: String?
        let size: Int?
    }

    func header(_ name: String) -> String? {
        payload?.headers?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    func toSummary() -> GmailMessageSummary {
        let date = parsedDate()
        let from = header("From") ?? ""
        let parsed = MailAddressParser.parse(from)
        let labels = labelIds ?? []
        return GmailMessageSummary(
            id: id,
            threadId: threadId,
            snippet: (snippet ?? "").decodingHTMLEntities,
            subject: header("Subject") ?? "(no subject)",
            fromName: parsed.name,
            fromAddress: parsed.address,
            date: date,
            unread: labels.contains("UNREAD"),
            starred: labels.contains("STARRED"),
            labelIDs: labels
        )
    }

    func toFullMessage() -> GmailMessage {
        let from = MailAddressParser.parse(header("From") ?? "")
        let plain = decodeBody(mimeType: "text/plain")
        let html = decodeBody(mimeType: "text/html")
        return GmailMessage(
            id: id,
            threadId: threadId,
            subject: header("Subject") ?? "(no subject)",
            fromName: from.name,
            fromAddress: from.address,
            to: header("To") ?? "",
            cc: header("Cc"),
            date: parsedDate(),
            snippet: (snippet ?? "").decodingHTMLEntities,
            plainBody: plain ?? "",
            htmlBody: html,
            labelIDs: labelIds ?? [],
            unread: (labelIds ?? []).contains("UNREAD")
        )
    }

    private func parsedDate() -> Date {
        if let raw = internalDate, let millis = Int(raw) {
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
        return Date()
    }

    private func decodeBody(mimeType: String) -> String? {
        guard let payload else { return nil }
        return Self.findBody(in: payload, mimeType: mimeType)
    }

    private static func findBody(in payload: Payload, mimeType: String) -> String? {
        if let mt = payload.mimeType, mt.lowercased().hasPrefix(mimeType),
           let data = payload.body?.data, let decoded = decodeBase64URL(data) {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let found = findBody(in: part, mimeType: mimeType) {
                return found
            }
        }
        return nil
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var clean = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while clean.count % 4 != 0 { clean.append("=") }
        guard let data = Data(base64Encoded: clean) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum MailAddressParser {
    struct Address {
        let name: String
        let address: String
    }
    /// Splits an RFC-5322-style address like `"Jane Doe" <jane@example.com>`
    /// into a display name + bare address. Falls back to the raw string for
    /// either field if parsing fails.
    static func parse(_ raw: String) -> Address {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Address(name: "", address: "") }
        if let lt = trimmed.firstIndex(of: "<"), let gt = trimmed.firstIndex(of: ">"), lt < gt {
            let name = trimmed[..<lt]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let address = String(trimmed[trimmed.index(after: lt)..<gt])
            return Address(name: name.isEmpty ? address : name, address: address)
        }
        return Address(name: trimmed, address: trimmed)
    }
}

private extension String {
    /// Decode the handful of HTML entities Gmail snippets contain — the
    /// snippet is plain text but the API returns it with HTML escapes.
    var decodingHTMLEntities: String {
        var copy = self
        for (escape, replacement) in [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " ")
        ] {
            copy = copy.replacingOccurrences(of: escape, with: replacement)
        }
        return copy
    }
}
