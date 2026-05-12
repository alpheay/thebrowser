import Foundation

/// One row in the downloads log. Mirrors the schema in ``DownloadsStore`` —
/// see that file for the SQLite columns. Identifiers are UUID strings so the
/// in-memory ``DownloadController`` and the persisted store share the same
/// key without round-tripping through SQLite's `rowid`.
struct DownloadRecord: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case pending
        case active
        case paused
        case completed
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .pending, .active, .paused: return false
            }
        }

        var isInFlight: Bool {
            switch self {
            case .pending, .active, .paused: return true
            case .completed, .failed, .cancelled: return false
            }
        }
    }

    var id: String
    var url: String
    var filename: String
    var destinationPath: String
    var mimeType: String
    var startedAt: Date
    var completedAt: Date?
    var bytesReceived: Int64
    var bytesTotal: Int64?
    var state: State
    var errorMessage: String?
}
