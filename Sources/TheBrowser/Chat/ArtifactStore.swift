import Foundation

/// Persists generated AI artifacts under ``~/.thebrowser/web_artifacts/<stamp>_<slug>.html``.
/// Each artifact is a self-contained HTML document — also opens correctly in
/// any browser when launched from disk.
@MainActor
final class ArtifactStore {
    static let shared = ArtifactStore()

    /// Posted (on the main actor) whenever the artifact collection changes —
    /// a new artifact is saved or an existing one is deleted. The artifact
    /// gallery observes this to refresh, mirroring `HistoryStore.didChangeNotification`.
    static let didChangeNotification = Notification.Name("ArtifactStore.didChange")

    nonisolated static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("web_artifacts", isDirectory: true)
    }()

    /// Cached thumbnail PNGs live under a hidden subfolder of the artifacts
    /// root. `enumerate()` skips hidden files, so they never show up as
    /// artifacts. Owned here (not by the renderer) so `delete` can clean them up.
    nonisolated static let thumbnailsRootURL: URL = rootURL.appendingPathComponent(".thumbnails", isDirectory: true)

    /// Disk location of the cached thumbnail for an artifact file name, e.g.
    /// `2026-05-22_…_market-brief.html` -> `<thumbnails>/2026-05-22_…_market-brief.html.png`.
    nonisolated static func thumbnailURL(forArtifactNamed fileName: String) -> URL {
        thumbnailsRootURL.appendingPathComponent(fileName + ".png", isDirectory: false)
    }

    private let root: URL

    init(root: URL = ArtifactStore.rootURL) {
        self.root = root
    }

    /// Writes `html` to disk under the artifacts root and returns the file URL.
    /// Filename format: `yyyy-MM-dd_HH-mm-ss_<slug>.html`. Slug is derived from
    /// `title`; falls back to "artifact" when the title has no usable characters.
    @discardableResult
    func save(title: String, html: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let slug = Self.slug(from: title)
        let filename = "\(Self.timestamp())_\(slug).html"
        let url = root.appendingPathComponent(filename, isDirectory: false)
        try html.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return url
    }

    /// Enumerates every saved artifact, newest first. Hidden files (the
    /// `.thumbnails` cache) are skipped, and non-HTML entries are ignored.
    /// `session` and `thumbnailURL` are left unset — the gallery model joins
    /// the chat-session index and the renderer resolves thumbnails.
    func enumerate() -> [ArtifactMetadata] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .compactMap { ArtifactMetadata.make(url: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes an artifact's `.html` file and its cached thumbnail, then
    /// posts ``didChangeNotification``. Past chat tool-rows that reference the
    /// file become dead links — acceptable for now.
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.thumbnailURL(forArtifactNamed: url.lastPathComponent))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// Lowercases, replaces runs of non-alphanumerics with a dash, trims dashes.
    /// Caps at 60 characters so filenames stay manageable.
    nonisolated static func slug(from title: String) -> String {
        let lowered = title.lowercased()
        var current = ""
        var last: Character = "-"
        for character in lowered {
            if character.isLetter || character.isNumber {
                current.append(character)
                last = character
            } else if last != "-" {
                current.append("-")
                last = "-"
            }
        }
        let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let bounded = String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return bounded.isEmpty ? "artifact" : bounded
    }
}
