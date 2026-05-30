import CryptoKit
import Foundation

/// Value types for the local "answer from my history" subsystem (Recall).
///
/// Recall is a privacy-first knowledge index layered over ``HistoryStore``:
/// page *content* the user actually read is extracted on-device, chunked,
/// embedded with an on-device model, and indexed in a local SQLite file
/// (`~/.thebrowser/recall.sqlite`). Nothing in this pipeline leaves the
/// machine — see ``RecallStore`` and ``RecallController``. The only data that
/// can ever reach a cloud model is the handful of passages a query retrieves,
/// surfaced as visible citations when the agent answers.

// MARK: - Capture

/// A single page snapshot handed to the indexer after the user dwells on it.
/// `Sendable` so it can cross from the `@MainActor` capture site into the
/// `RecallStore` actor.
struct CapturedPage: Sendable, Equatable {
    var url: URL
    var title: String
    var host: String
    var text: String
    var wordCount: Int
    var lang: String?
    /// Seconds of foreground reading attributed to *this* capture. Accumulated
    /// into the document's running `dwell_seconds` — a memorability signal.
    var dwellSeconds: Double
    var capturedAt: Date

    /// Stable fingerprint of the readable body. Lets the indexer skip the
    /// expensive re-chunk/re-embed pass when a revisit yields identical text,
    /// while still bumping the view/dwell counters.
    var contentHash: String {
        RecallHashing.hash(text)
    }
}

enum RecallHashing {
    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Chunks

/// One passage of a captured page, the unit of both lexical (FTS) and
/// semantic (vector) retrieval. Articles are chunked so a query retrieves the
/// relevant paragraph rather than a whole document.
struct RecallChunkInput: Sendable, Equatable {
    var ordinal: Int
    var heading: String?
    var text: String
    var tokenCount: Int
}

// MARK: - Retrieval results

/// A ranked retrieval result — one passage plus its source-page metadata and
/// the blended relevance/memorability score. Drives both the agent `recall`
/// tool's citations and the instant-recall panel rows.
struct RecallHit: Sendable, Identifiable, Equatable {
    var id: Int64            // chunk rowid
    var url: URL
    var title: String
    var host: String
    var heading: String?
    var snippet: String
    var lastVisitedAt: Date
    var capturedAt: Date
    var visitCount: Int
    var dwellSeconds: Double
    var starred: Bool
    /// Final blended score (relevance × recency × engagement). Higher is better.
    var score: Double
    var lexicalScore: Double?
    var semanticScore: Double?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !host.isEmpty { return host }
        return url.absoluteString
    }
}

/// A page-level row in the index, used for "related pages" (proactive
/// connections) and index housekeeping.
struct RecallDocument: Sendable, Identifiable, Equatable {
    var url: URL
    var title: String
    var host: String
    var lastVisitedAt: Date
    var visitCount: Int
    var dwellSeconds: Double
    var wordCount: Int
    var starred: Bool

    var id: String { url.absoluteString }
}

/// Index size, surfaced in Settings so the on-device footprint is never a
/// mystery (and deletions visibly shrink it).
struct RecallStats: Sendable, Equatable {
    var documentCount: Int
    var chunkCount: Int
    var byteSize: Int

    static let empty = RecallStats(documentCount: 0, chunkCount: 0, byteSize: 0)
}

// MARK: - Query plan

/// A parsed recall query: free-text keywords plus structured filters the model
/// (or panel) couldn't express as embeddings — "last week" is a date range,
/// "on nytimes" is a host filter. Produced by ``RecallQueryPlanner``.
struct RecallQuery: Sendable, Equatable {
    var rawText: String
    /// Cleaned keyword string with temporal/host phrases stripped out.
    var terms: String
    var since: Date?
    var until: Date?
    var host: String?

    var hasTextQuery: Bool {
        !terms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasFilters: Bool {
        since != nil || until != nil || host != nil
    }
}

// MARK: - Blob helpers

extension Data {
    /// Packs a vector into a little-endian `Float32` blob for the `embedding`
    /// column. Round-trips on the same machine, which is all the local index
    /// ever needs.
    init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func toFloatArray() -> [Float] {
        let count = self.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: buffer.baseAddress, count: count))
        }
    }
}

// MARK: - Host normalization

enum RecallHost {
    /// Canonical host for indexing/filtering: lowercased, `www.` stripped.
    /// "https://www.NYTimes.com/x" → "nytimes.com".
    static func normalize(_ host: String?) -> String {
        guard var host = host?.lowercased(), !host.isEmpty else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    static func normalize(url: URL) -> String {
        normalize(url.host(percentEncoded: false))
    }
}
