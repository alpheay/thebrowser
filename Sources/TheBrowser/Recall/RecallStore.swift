import Foundation
import SQLite3

/// On-device knowledge index for Recall — `~/.thebrowser/recall.sqlite`.
///
/// Deliberately an `actor`, not a `@MainActor` singleton like ``HistoryStore``:
/// extraction, chunking, embedding, and search must never block the UI. The
/// actor serializes every statement against its own connection, so a second
/// connection to a different file (history.sqlite) and the main thread run
/// concurrently. WAL mode keeps readers and the writer from blocking.
///
/// Storage is three tables — `documents` (one per captured page), `chunks`
/// (retrieval passages, each with an optional on-device embedding), and an
/// FTS5 `chunk_fts` mirror for BM25 lexical search. Vector search is a bounded
/// brute-force cosine scan in Swift; at the scale a single person browses that
/// is sub-10ms and needs zero native dependencies. (sqlite-vec is the drop-in
/// upgrade when an index outgrows the scan cap.)
actor RecallStore {
    static let shared = RecallStore()

    nonisolated static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("recall.sqlite")
    }

    /// Upper bound on embeddings pulled into memory for a single semantic
    /// scan. Past this the most-recent chunks win and older ones fall back to
    /// lexical-only — logged, never silent. Raise (or swap in sqlite-vec) when
    /// real indexes routinely exceed it.
    private static let maxVectorScan = 20_000

    private let databaseURL: URL
    private var db: OpaquePointer?
    private var didOpen = false
    private var ftsAvailable = false

    init(databaseURL: URL = RecallStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Capture / indexing

    /// Indexes (or refreshes) a captured page. When the body is unchanged
    /// since last capture we skip the re-chunk/re-embed work and just bump the
    /// memorability counters (view count, dwell, recency). `chunkEmbeddings`
    /// is parallel to `chunks`; pass nil to index lexical-only (Phase 1) or
    /// when the on-device embedder is unavailable.
    func index(
        _ page: CapturedPage,
        chunks: [RecallChunkInput],
        chunkEmbeddings: [[Float]]?,
        pageEmbedding: [Float]?
    ) {
        openIfNeeded()
        guard let db else { return }

        let urlString = page.url.absoluteString
        let host = RecallHost.normalize(url: page.url)
        let stamp = iso8601.string(from: page.capturedAt)
        let hash = page.contentHash

        if let existing = existingHash(forURL: urlString) {
            if existing == hash {
                // Same content — cheap counter bump only.
                bumpDocument(url: urlString, dwellSeconds: page.dwellSeconds, at: stamp)
                return
            }
        }

        exec("BEGIN IMMEDIATE TRANSACTION;")

        upsertDocument(
            url: urlString,
            title: page.title,
            host: host,
            lang: page.lang,
            wordCount: page.wordCount,
            contentHash: hash,
            dwellSeconds: page.dwellSeconds,
            stamp: stamp,
            pageEmbedding: pageEmbedding
        )
        deleteChunks(forURL: urlString)
        for (offset, chunk) in chunks.enumerated() {
            let embedding = chunkEmbeddings.flatMap { offset < $0.count ? $0[offset] : nil }
            insertChunk(url: urlString, chunk: chunk, embedding: embedding)
        }

        exec("COMMIT;")
    }

    /// Marks (or unmarks) a page as important — an explicit memorability
    /// signal that multiplies its ranking. Driven by the recall panel's star.
    func setStarred(url: URL, starred: Bool) {
        openIfNeeded()
        guard let db else { return }
        let sql = "UPDATE documents SET starred = ? WHERE url = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(stmt, 1, starred ? 1 : 0)
        bindText(stmt, 2, url.absoluteString)
        sqlite3_step(stmt)
    }

    // MARK: - Search

    /// Hybrid retrieval: BM25 lexical candidates fused with vector semantic
    /// candidates (reciprocal-rank fusion), re-weighted by recency and
    /// engagement, deduped to the single best passage per page. `queryVector`
    /// is the on-device embedding of the query; pass nil for lexical-only.
    func search(_ plan: RecallQuery, queryVector: [Float]?, limit: Int) -> [RecallHit] {
        openIfNeeded()
        guard db != nil else { return [] }
        let candidateLimit = min(300, max(limit * 6, 60))

        let lexical: [Int64]
        if plan.hasTextQuery {
            lexical = ftsAvailable
                ? ftsCandidates(plan, limit: candidateLimit)
                : likeCandidates(plan, limit: candidateLimit)
        } else {
            lexical = recencyCandidates(plan, limit: candidateLimit)
        }

        var semantic: [Int64] = []
        if let queryVector, !queryVector.isEmpty, plan.hasTextQuery {
            semantic = vectorCandidates(queryVector, plan: plan, limit: candidateLimit)
        }

        var lexicalRank: [Int64: Int] = [:]
        for (offset, id) in lexical.enumerated() { lexicalRank[id] = offset + 1 }
        var semanticRank: [Int64: Int] = [:]
        for (offset, id) in semantic.enumerated() { semanticRank[id] = offset + 1 }

        let ids = Array(Set(lexical + semantic))
        guard !ids.isEmpty else { return [] }
        let meta = fetchMeta(ids: ids)

        let now = Date()
        var hits: [RecallHit] = ids.compactMap { id in
            guard let row = meta[id] else { return nil }
            let signals = RecallRanker.Signals(
                lexicalRank: lexicalRank[id],
                semanticRank: semanticRank[id],
                ageSeconds: now.timeIntervalSince(row.lastVisitedAt),
                visitCount: row.visitCount,
                dwellSeconds: row.dwellSeconds,
                starred: row.starred
            )
            let score = RecallRanker.score(signals)
            guard score > 0 else { return nil }
            return RecallHit(
                id: id,
                url: row.url,
                title: row.title,
                host: row.host,
                heading: row.heading,
                snippet: Self.snippet(row.text),
                lastVisitedAt: row.lastVisitedAt,
                capturedAt: row.capturedAt,
                visitCount: row.visitCount,
                dwellSeconds: row.dwellSeconds,
                starred: row.starred,
                score: score,
                lexicalScore: lexicalRank[id].map { 1.0 / Double($0) },
                semanticScore: semanticRank[id].map { 1.0 / Double($0) }
            )
        }

        // Keep the single best passage per page, then rank pages.
        var bestPerURL: [String: RecallHit] = [:]
        for hit in hits {
            let key = hit.url.absoluteString
            if let existing = bestPerURL[key], existing.score >= hit.score { continue }
            bestPerURL[key] = hit
        }
        hits = Array(bestPerURL.values).sorted { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Pages semantically related to `url`, by page-embedding cosine —
    /// the backbone of proactive "you've read about this before" connections.
    func relatedDocuments(toURL url: URL, limit: Int) -> [RecallDocument] {
        openIfNeeded()
        guard let db else { return [] }

        guard let anchor = pageEmbedding(forURL: url.absoluteString), !anchor.isEmpty else {
            return []
        }

        let sql = """
        SELECT url, title, host, last_visited_at, visit_count, dwell_seconds,
               word_count, starred, page_embedding
        FROM documents
        WHERE page_embedding IS NOT NULL AND url <> ?
        ORDER BY last_visited_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, url.absoluteString)
        sqlite3_bind_int(stmt, 2, Int32(Self.maxVectorScan))

        var scored: [(RecallDocument, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let doc = readDocument(stmt) else { continue }
            guard let blob = readBlob(stmt, 8) else { continue }
            let similarity = RecallRanker.cosineSimilarity(anchor, blob.toFloatArray())
            if similarity > 0.55 { scored.append((doc, similarity)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Deletion (cascade from HistoryStore)

    func delete(_ deletion: HistoryDeletion) {
        openIfNeeded()
        switch deletion {
        case .urls(let urls):
            for url in urls { deleteDocument(url: url) }
        case .host(let host):
            deleteHost(RecallHost.normalize(host))
        case .range(let range):
            deleteRange(range)
        case .all:
            deleteAll()
        }
    }

    // MARK: - Stats

    func stats() -> RecallStats {
        openIfNeeded()
        guard let db else { return .empty }
        let docs = scalarInt("SELECT COUNT(*) FROM documents;")
        let chunks = scalarInt("SELECT COUNT(*) FROM chunks;")
        let pageCount = scalarInt("PRAGMA page_count;")
        let pageSize = scalarInt("PRAGMA page_size;")
        return RecallStats(documentCount: docs, chunkCount: chunks, byteSize: pageCount * pageSize)
    }

    /// True when the on-device embedder has indexed at least one passage —
    /// lets the UI distinguish "semantic search ready" from "lexical only".
    func embeddedChunkCount() -> Int {
        openIfNeeded()
        return scalarInt("SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL;")
    }

    // MARK: - Candidate queries

    private func ftsCandidates(_ plan: RecallQuery, limit: Int) -> [Int64] {
        guard let db, let match = Self.ftsMatchQuery(plan.terms) else { return [] }
        var sql = """
        SELECT chunk_fts.rowid, bm25(chunk_fts) AS rank
        FROM chunk_fts
        JOIN chunks ON chunks.id = chunk_fts.rowid
        JOIN documents ON documents.url = chunks.url
        WHERE chunk_fts MATCH ?
        """
        sql += filterClause(plan)
        sql += " ORDER BY rank LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError("prepare fts")
            return []
        }
        var index: Int32 = 1
        bindText(stmt, index, match); index += 1
        index = bindFilters(stmt, plan, from: index)
        sqlite3_bind_int(stmt, index, Int32(limit))

        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    private func likeCandidates(_ plan: RecallQuery, limit: Int) -> [Int64] {
        guard let db else { return [] }
        var sql = """
        SELECT chunks.id
        FROM chunks
        JOIN documents ON documents.url = chunks.url
        WHERE chunks.text LIKE ? ESCAPE '\\'
        """
        sql += filterClause(plan)
        sql += " ORDER BY documents.last_visited_at DESC LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var index: Int32 = 1
        bindText(stmt, index, "%\(Self.escapeLike(plan.terms))%"); index += 1
        index = bindFilters(stmt, plan, from: index)
        sqlite3_bind_int(stmt, index, Int32(limit))

        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    /// Newest passages within the filter — used when the query is pure
    /// temporal/host ("what did I read last week").
    private func recencyCandidates(_ plan: RecallQuery, limit: Int) -> [Int64] {
        guard let db else { return [] }
        var sql = """
        SELECT chunks.id
        FROM chunks
        JOIN documents ON documents.url = chunks.url
        WHERE chunks.ordinal = 0
        """
        sql += filterClause(plan)
        sql += " ORDER BY documents.last_visited_at DESC LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var index = bindFilters(stmt, plan, from: 1)
        sqlite3_bind_int(stmt, index, Int32(limit))

        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    private func vectorCandidates(_ query: [Float], plan: RecallQuery, limit: Int) -> [Int64] {
        guard let db else { return [] }
        var sql = """
        SELECT chunks.id, chunks.embedding
        FROM chunks
        JOIN documents ON documents.url = chunks.url
        WHERE chunks.embedding IS NOT NULL
        """
        sql += filterClause(plan)
        sql += " ORDER BY documents.last_visited_at DESC LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var index = bindFilters(stmt, plan, from: 1)
        sqlite3_bind_int(stmt, index, Int32(Self.maxVectorScan))

        var scored: [(Int64, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let blob = readBlob(stmt, 1) else { continue }
            let similarity = RecallRanker.cosineSimilarity(query, blob.toFloatArray())
            if similarity > 0.2 { scored.append((id, similarity)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Filter SQL

    private func filterClause(_ plan: RecallQuery) -> String {
        var clause = ""
        if plan.host != nil { clause += " AND documents.host = ?" }
        if plan.since != nil { clause += " AND documents.last_visited_at >= ?" }
        if plan.until != nil { clause += " AND documents.last_visited_at <= ?" }
        return clause
    }

    private func bindFilters(_ stmt: OpaquePointer?, _ plan: RecallQuery, from index: Int32) -> Int32 {
        var index = index
        if let host = plan.host { bindText(stmt, index, RecallHost.normalize(host)); index += 1 }
        if let since = plan.since { bindText(stmt, index, iso8601.string(from: since)); index += 1 }
        if let until = plan.until { bindText(stmt, index, iso8601.string(from: until)); index += 1 }
        return index
    }

    // MARK: - Metadata fetch

    private struct ChunkMeta {
        var url: URL
        var title: String
        var host: String
        var heading: String?
        var text: String
        var lastVisitedAt: Date
        var capturedAt: Date
        var visitCount: Int
        var dwellSeconds: Double
        var starred: Bool
    }

    private func fetchMeta(ids: [Int64]) -> [Int64: ChunkMeta] {
        guard let db, !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT chunks.id, chunks.url, chunks.heading, chunks.text,
               documents.title, documents.host, documents.last_visited_at,
               documents.last_captured_at, documents.visit_count,
               documents.dwell_seconds, documents.starred
        FROM chunks
        JOIN documents ON documents.url = chunks.url
        WHERE chunks.id IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        for (offset, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(offset + 1), id)
        }

        var result: [Int64: ChunkMeta] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let url = URL(string: readText(stmt, 1)) else { continue }
            result[id] = ChunkMeta(
                url: url,
                title: readText(stmt, 4),
                host: readText(stmt, 5),
                heading: readOptionalText(stmt, 2),
                text: readText(stmt, 3),
                lastVisitedAt: date(readText(stmt, 6)),
                capturedAt: date(readText(stmt, 7)),
                visitCount: Int(sqlite3_column_int(stmt, 8)),
                dwellSeconds: sqlite3_column_double(stmt, 9),
                starred: sqlite3_column_int(stmt, 10) != 0
            )
        }
        return result
    }

    // MARK: - Document writes

    private func upsertDocument(
        url: String,
        title: String,
        host: String,
        lang: String?,
        wordCount: Int,
        contentHash: String,
        dwellSeconds: Double,
        stamp: String,
        pageEmbedding: [Float]?
    ) {
        guard let db else { return }
        let sql = """
        INSERT INTO documents (
            url, title, host, lang, word_count, content_hash,
            first_captured_at, last_captured_at, last_visited_at,
            visit_count, dwell_seconds, starred, page_embedding
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, ?)
        ON CONFLICT(url) DO UPDATE SET
            title = excluded.title,
            host = excluded.host,
            lang = excluded.lang,
            word_count = excluded.word_count,
            content_hash = excluded.content_hash,
            last_captured_at = excluded.last_captured_at,
            last_visited_at = excluded.last_visited_at,
            visit_count = documents.visit_count + 1,
            dwell_seconds = documents.dwell_seconds + excluded.dwell_seconds,
            page_embedding = excluded.page_embedding;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError("prepare upsert document")
            return
        }
        bindText(stmt, 1, url)
        bindText(stmt, 2, title)
        bindText(stmt, 3, host)
        bindOptionalText(stmt, 4, lang)
        sqlite3_bind_int(stmt, 5, Int32(wordCount))
        bindText(stmt, 6, contentHash)
        bindText(stmt, 7, stamp)
        bindText(stmt, 8, stamp)
        bindText(stmt, 9, stamp)
        sqlite3_bind_double(stmt, 10, dwellSeconds)
        bindBlob(stmt, 11, pageEmbedding.map { Data(floats: $0) })
        if sqlite3_step(stmt) != SQLITE_DONE { logError("step upsert document") }
    }

    private func bumpDocument(url: String, dwellSeconds: Double, at stamp: String) {
        guard let db else { return }
        let sql = """
        UPDATE documents SET
            visit_count = visit_count + 1,
            dwell_seconds = dwell_seconds + ?,
            last_visited_at = ?
        WHERE url = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, dwellSeconds)
        bindText(stmt, 2, stamp)
        bindText(stmt, 3, url)
        sqlite3_step(stmt)
    }

    private func insertChunk(url: String, chunk: RecallChunkInput, embedding: [Float]?) {
        guard let db else { return }
        let sql = """
        INSERT INTO chunks (url, ordinal, heading, text, token_count, embedding)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError("prepare insert chunk")
            return
        }
        bindText(stmt, 1, url)
        sqlite3_bind_int(stmt, 2, Int32(chunk.ordinal))
        bindOptionalText(stmt, 3, chunk.heading)
        bindText(stmt, 4, chunk.text)
        sqlite3_bind_int(stmt, 5, Int32(chunk.tokenCount))
        bindBlob(stmt, 6, embedding.map { Data(floats: $0) })
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            logError("step insert chunk")
            return
        }
        let rowID = sqlite3_last_insert_rowid(db)
        if ftsAvailable { insertFTS(rowID: rowID, url: url, heading: chunk.heading, text: chunk.text) }
    }

    private func insertFTS(rowID: Int64, url: String, heading: String?, text: String) {
        guard let db else { return }
        let sql = "INSERT INTO chunk_fts (rowid, text, heading, url) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, rowID)
        bindText(stmt, 2, text)
        bindText(stmt, 3, heading ?? "")
        bindText(stmt, 4, url)
        sqlite3_step(stmt)
    }

    // MARK: - Deletes

    private func deleteChunks(forURL url: String) {
        guard let db else { return }
        if ftsAvailable {
            execBound(
                "DELETE FROM chunk_fts WHERE rowid IN (SELECT id FROM chunks WHERE url = ?);",
                text: url
            )
        }
        execBound("DELETE FROM chunks WHERE url = ?;", text: url)
    }

    private func deleteDocument(url: String) {
        deleteChunks(forURL: url)
        execBound("DELETE FROM documents WHERE url = ?;", text: url)
    }

    private func deleteHost(_ host: String) {
        guard !host.isEmpty else { return }
        if ftsAvailable {
            execBound("""
            DELETE FROM chunk_fts WHERE rowid IN (
                SELECT chunks.id FROM chunks
                JOIN documents ON documents.url = chunks.url
                WHERE documents.host = ?
            );
            """, text: host)
        }
        execBound("DELETE FROM chunks WHERE url IN (SELECT url FROM documents WHERE host = ?);", text: host)
        execBound("DELETE FROM documents WHERE host = ?;", text: host)
    }

    private func deleteRange(_ range: ClosedRange<Date>) {
        guard let db else { return }
        let lower = iso8601.string(from: range.lowerBound)
        let upper = iso8601.string(from: range.upperBound)
        if ftsAvailable {
            let sql = """
            DELETE FROM chunk_fts WHERE rowid IN (
                SELECT chunks.id FROM chunks
                JOIN documents ON documents.url = chunks.url
                WHERE documents.last_visited_at BETWEEN ? AND ?
            );
            """
            execBound2(sql, lower, upper)
        }
        execBound2("""
        DELETE FROM chunks WHERE url IN (
            SELECT url FROM documents WHERE last_visited_at BETWEEN ? AND ?
        );
        """, lower, upper)
        execBound2("DELETE FROM documents WHERE last_visited_at BETWEEN ? AND ?;", lower, upper)
    }

    private func deleteAll() {
        if ftsAvailable { exec("DELETE FROM chunk_fts;") }
        exec("DELETE FROM chunks;")
        exec("DELETE FROM documents;")
    }

    // MARK: - Small reads

    private func existingHash(forURL url: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT content_hash FROM documents WHERE url = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        bindText(stmt, 1, url)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readOptionalText(stmt, 0)
    }

    private func pageEmbedding(forURL url: String) -> [Float]? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT page_embedding FROM documents WHERE url = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        bindText(stmt, 1, url)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readBlob(stmt, 0)?.toFloatArray()
    }

    private func readDocument(_ stmt: OpaquePointer?) -> RecallDocument? {
        guard let url = URL(string: readText(stmt, 0)) else { return nil }
        return RecallDocument(
            url: url,
            title: readText(stmt, 1),
            host: readText(stmt, 2),
            lastVisitedAt: date(readText(stmt, 3)),
            visitCount: Int(sqlite3_column_int(stmt, 4)),
            dwellSeconds: sqlite3_column_double(stmt, 5),
            wordCount: Int(sqlite3_column_int(stmt, 6)),
            starred: sqlite3_column_int(stmt, 7) != 0
        )
    }

    private func scalarInt(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Schema / lifecycle

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true

        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            db = nil
            return
        }
        db = handle

        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=3000;")
        exec("PRAGMA synchronous=NORMAL;")

        let schema = """
        CREATE TABLE IF NOT EXISTS documents (
            url TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            host TEXT NOT NULL DEFAULT '',
            lang TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT NOT NULL DEFAULT '',
            first_captured_at TEXT NOT NULL,
            last_captured_at TEXT NOT NULL,
            last_visited_at TEXT NOT NULL,
            visit_count INTEGER NOT NULL DEFAULT 1,
            dwell_seconds REAL NOT NULL DEFAULT 0,
            starred INTEGER NOT NULL DEFAULT 0,
            page_embedding BLOB
        );
        CREATE INDEX IF NOT EXISTS documents_host ON documents (host);
        CREATE INDEX IF NOT EXISTS documents_last_visited ON documents (last_visited_at DESC);

        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            ordinal INTEGER NOT NULL DEFAULT 0,
            heading TEXT,
            text TEXT NOT NULL,
            token_count INTEGER NOT NULL DEFAULT 0,
            embedding BLOB
        );
        CREATE INDEX IF NOT EXISTS chunks_url ON chunks (url);
        """
        exec(schema)

        // FTS5 ships in Apple's system libsqlite3, but degrade to LIKE if a
        // stripped build ever lacks it rather than losing search entirely.
        let ftsSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
            text, heading, url UNINDEXED, tokenize='porter unicode61'
        );
        """
        ftsAvailable = sqlite3_exec(handle, ftsSQL, nil, nil, nil) == SQLITE_OK
        if !ftsAvailable { logError("FTS5 unavailable — falling back to LIKE search") }
    }

    // MARK: - SQLite helpers (mirror HistoryStore's style)

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func execBound(_ sql: String, text: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, text)
        sqlite3_step(stmt)
    }

    private func execBound2(_ sql: String, _ a: String, _ b: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, a)
        bindText(stmt, 2, b)
        sqlite3_step(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data?) {
        guard let data, !data.isEmpty else { sqlite3_bind_null(stmt, index); return }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), transient)
        }
    }

    private func readText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func readOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func readBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func logError(_ context: String) {
        #if DEBUG
        if let db, let message = sqlite3_errmsg(db) {
            print("RecallStore [\(context)]:", String(cString: message))
        } else {
            print("RecallStore [\(context)]")
        }
        #endif
    }

    // MARK: - Static helpers

    /// Turns user keywords into a recall-friendly FTS5 MATCH: each token
    /// becomes a quoted prefix term, joined by OR for breadth (ranking
    /// supplies the precision). Returns nil when nothing indexable remains, so
    /// the caller can fall back to a recency listing.
    static func ftsMatchQuery(_ terms: String) -> String? {
        let tokens = terms
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func snippet(_ text: String, limit: Int = 320) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func date(_ string: String) -> Date {
        iso8601.date(from: string) ?? .distantPast
    }

    /// Actor-isolated so the (non-`Sendable`) formatter is never shared across
    /// threads. ISO8601 with fractional seconds, matching ``HistoryStore``.
    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
