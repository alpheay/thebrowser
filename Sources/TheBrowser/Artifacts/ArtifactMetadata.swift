import Foundation

/// Back-reference from an artifact to the chat session that produced it.
/// Built by ``ChatSessionStore/artifactSessionIndex()`` and joined onto
/// ``ArtifactMetadata`` so the gallery can jump back into the conversation.
struct ArtifactSessionRef: Equatable, Hashable, Sendable {
    let sessionID: String
    let pageTitle: String
    let firstUserMessage: String?
    let updatedAt: Date
}

/// One artifact on disk, resolved enough to render a gallery card without
/// opening the file. Built by ``ArtifactStore/enumerate()``; the optional
/// fields are filled in later (``session`` by the gallery model's join,
/// ``thumbnailURL`` by ``ArtifactThumbnailRenderer``).
struct ArtifactMetadata: Identifiable, Equatable, Sendable {
    /// The file name (e.g. `2026-05-22_23-56-56_market-brief.html`). Stable
    /// and unique — used as the gallery's identity and the join key against
    /// the chat-session index.
    let id: String
    let url: URL
    let title: String
    let createdAt: Date
    let fileSize: Int
    var session: ArtifactSessionRef?
    var thumbnailURL: URL?

    var fileName: String { id }
}

extension ArtifactMetadata {
    /// Builds metadata for a single artifact file. Reads only the file's head
    /// for the `<title>` and parses the timestamp from the name, so it stays
    /// cheap to run across the whole directory. Returns `nil` for non-HTML
    /// entries. `nonisolated` so it can run off the main actor and in tests.
    nonisolated static func make(url: URL) -> ArtifactMetadata? {
        guard url.pathExtension.lowercased() == "html" else { return nil }
        let fileName = url.lastPathComponent

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let size = values?.fileSize ?? 0
        let created = parseTimestamp(fileName: fileName)
            ?? values?.creationDate
            ?? .distantPast
        let title = headTitle(of: url) ?? desluggedTitle(fileName: fileName)

        return ArtifactMetadata(
            id: fileName,
            url: url,
            title: title,
            createdAt: created,
            fileSize: size
        )
    }

    /// Parses the `yyyy-MM-dd_HH-mm-ss` UTC prefix that ``ArtifactStore`` writes
    /// (the inverse of its private `timestamp()`). Returns `nil` for files that
    /// don't follow the convention (e.g. an HTML file dropped in by hand).
    nonisolated static func parseTimestamp(fileName: String) -> Date? {
        guard fileName.count >= 19 else { return nil }
        let stamp = String(fileName.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        return formatter.date(from: stamp)
    }

    /// Fallback title derived from the filename slug when the document has no
    /// readable `<title>`: drops the stamp prefix and `.html`, turns dashes
    /// back into spaced, capitalized words.
    nonisolated static func desluggedTitle(fileName: String) -> String {
        var name = fileName
        if name.lowercased().hasSuffix(".html") {
            name = String(name.dropLast(5))
        }
        // Strip a leading "yyyy-MM-dd_HH-mm-ss_" stamp (20 chars) only when
        // the name actually carries one.
        if parseTimestamp(fileName: fileName) != nil, name.count > 20 {
            name = String(name.dropFirst(20))
        }
        let words = name
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.capitalized }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "Artifact" : joined
    }

    /// Reads the first 16 KB of the file and pulls the `<title>` text. Kept
    /// deliberately small — artifacts can embed large inline data, and the
    /// title always sits in the document head.
    nonisolated private static func headTitle(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), !data.isEmpty else { return nil }
        let head = String(decoding: data, as: UTF8.self)

        guard let regex = try? NSRegularExpression(pattern: #"(?is)<title[^>]*>(.*?)</title>"#) else {
            return nil
        }
        let range = NSRange(head.startIndex..<head.endIndex, in: head)
        guard let match = regex.firstMatch(in: head, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: head) else {
            return nil
        }
        let stripped = String(head[captured])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}
