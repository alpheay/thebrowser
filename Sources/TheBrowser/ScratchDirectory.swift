import Foundation

struct ScratchDirectory: @unchecked Sendable {
    static let shared = ScratchDirectory()

    private static let mappingDefaultsKey = "scratch.windowUUIDMapping"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.applicationSupportDirectory = support.appendingPathComponent("TheBrowser", isDirectory: true)
        }
    }

    var rootDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("scratch", isDirectory: true)
    }

    func url(forWindow windowID: String) -> URL {
        let uuid = scratchUUID(forWindow: windowID)
        return rootDirectory
            .appendingPathComponent("win-\(uuid.uuidString)", isDirectory: true)
    }

    @discardableResult
    func ensureExists(forWindow windowID: String) throws -> URL {
        let url = url(forWindow: windowID)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        // TODO: Thread integration should own scratch directory lifecycle; do not delete on window close here.
        return url
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String, forWindow windowID: String) throws -> URL {
        let directory = try ensureExists(forWindow: windowID)
        let destination = try resolvedChildURL(relativePath: relativePath, in: directory)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func scratchUUID(forWindow windowID: String) -> UUID {
        let normalizedWindowID = windowID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedWindowID.isEmpty ? "default-window" : normalizedWindowID
        var mapping = defaults.dictionary(forKey: Self.mappingDefaultsKey) as? [String: String] ?? [:]

        if let stored = mapping[key], let uuid = UUID(uuidString: stored) {
            return uuid
        }

        let uuid = UUID()
        mapping[key] = uuid.uuidString
        defaults.set(mapping, forKey: Self.mappingDefaultsKey)
        return uuid
    }

    private func resolvedChildURL(relativePath: String, in directory: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw ScratchDirectoryError.invalidRelativePath(relativePath)
        }

        let destination = directory.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        let rootPath = directory.standardizedFileURL.path
        let destinationPath = destination.path
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
            throw ScratchDirectoryError.invalidRelativePath(relativePath)
        }

        return destination
    }
}

enum ScratchDirectoryError: LocalizedError, Equatable {
    case invalidRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "Scratch paths must be relative to the window scratch directory: \(path)"
        }
    }
}
