import Foundation

/// Persists generated AI artifacts under ``~/.thebrowser/web_artifacts/<stamp>_<slug>.html``.
/// Each artifact is a self-contained HTML document — also opens correctly in
/// any browser when launched from disk.
@MainActor
final class ArtifactStore {
    static let shared = ArtifactStore()

    static let rootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("web_artifacts", isDirectory: true)
    }()

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
        return url
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
