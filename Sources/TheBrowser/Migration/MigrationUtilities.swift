import CryptoKit
import Foundation

enum MigrationError: LocalizedError {
    case profileUnavailable(String)
    case sqliteFailed(String)
    case processFailed(String)
    case decryptionUnavailable(String)
    case keychainFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileUnavailable(let detail):
            "Profile unavailable: \(detail)"
        case .sqliteFailed(let detail):
            "Could not read browser database: \(detail)"
        case .processFailed(let detail):
            "A helper process failed: \(detail)"
        case .decryptionUnavailable(let detail):
            "Could not decrypt browser data: \(detail)"
        case .keychainFailed(let detail):
            "Could not save passwords: \(detail)"
        }
    }
}

enum MigrationFileSystem {
    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func existingDirectories(_ candidates: [URL]) -> [URL] {
        candidates.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func temporaryCopy(of source: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw MigrationError.profileUnavailable(source.path)
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("TheBrowserMigration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let copiedDatabase = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: copiedDatabase)

        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try? fileManager.copyItem(
                at: sidecar,
                to: URL(fileURLWithPath: copiedDatabase.path + suffix)
            )
        }

        return copiedDatabase
    }

    static func removeTemporaryCopy(_ databaseCopy: URL) {
        try? FileManager.default.removeItem(at: databaseCopy.deletingLastPathComponent())
    }
}

enum SQLiteJSON {
    static func query<Row: Decodable>(_ database: URL, sql: String, as rowType: Row.Type) throws -> [Row] {
        let databaseCopy = try MigrationFileSystem.temporaryCopy(of: database)
        defer { MigrationFileSystem.removeTemporaryCopy(databaseCopy) }

        let output = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", "-json", databaseCopy.path, sql]
        )

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([Row].self, from: Data(trimmed.utf8))
        } catch {
            throw MigrationError.sqliteFailed(error.localizedDescription)
        }
    }
}

struct ProcessOutput {
    var stdout: String
    var stderr: String
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        do {
            try process.run()
            if let input, let stdinPipe {
                stdinPipe.fileHandleForWriting.write(input)
                try? stdinPipe.fileHandleForWriting.close()
            }
            process.waitUntilExit()
        } catch {
            throw MigrationError.processFailed(error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MigrationError.processFailed(detail.isEmpty ? executable.path : detail)
        }

        return ProcessOutput(stdout: stdout, stderr: stderr)
    }
}

enum PasswordKeyDerivation {
    static func pbkdf2SHA1(password: Data, salt: Data, iterations: Int, keyByteCount: Int) -> Data {
        var derivedKey = Data()
        var blockIndex: UInt32 = 1

        while derivedKey.count < keyByteCount {
            var blockSalt = salt
            blockSalt.append(contentsOf: withUnsafeBytes(of: blockIndex.bigEndian) { Array($0) })

            var digest = Data(HMAC<Insecure.SHA1>.authenticationCode(
                for: blockSalt,
                using: SymmetricKey(data: password)
            ))
            var block = digest

            if iterations > 1 {
                for _ in 1..<iterations {
                    digest = Data(HMAC<Insecure.SHA1>.authenticationCode(
                        for: digest,
                        using: SymmetricKey(data: password)
                    ))
                    block.xorInPlace(with: digest)
                }
            }

            derivedKey.append(block)
            blockIndex += 1
        }

        return derivedKey.prefix(keyByteCount)
    }
}

extension Data {
    init?(hexEncoded hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard nextIndex <= hex.endIndex else { return nil }
            let byteString = hex[index..<nextIndex]
            guard byteString.count == 2, let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func xorInPlace(with other: Data) {
        let count = Swift.min(count, other.count)
        for index in 0..<count {
            self[index] ^= other[index]
        }
    }
}

extension Date {
    static func chromeDate(microsecondsSince1601 value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let secondsBetween1601And1970: TimeInterval = 11_644_473_600
        let seconds = TimeInterval(value) / 1_000_000 - secondsBetween1601And1970
        return Date(timeIntervalSince1970: seconds)
    }

    static func firefoxDate(microsecondsSince1970 value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000_000)
    }
}
