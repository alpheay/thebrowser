import Combine
import Foundation

/// Main-actor façade over the Recall subsystem. Owns settings, orchestrates
/// capture → chunk → (embed) → index off the main thread, runs queries, and
/// mirrors history deletions into the index so "forget this site" / "clear
/// history" stay honest. The heavy lifting lives in the ``RecallStore`` actor;
/// this type is the thin, observable seam the UI and agent tool talk to.
@MainActor
final class RecallController: ObservableObject {
    static let shared = RecallController()

    /// Index footprint, surfaced in Settings. Refreshed on demand.
    @Published private(set) var stats: RecallStats = .empty
    /// Whether the on-device embedder has indexed anything yet — drives the
    /// "semantic search ready" vs "lexical only" hint.
    @Published private(set) var semanticReady = false

    private var didActivate = false
    /// Pages skip a fresh capture for this long after being indexed, so a
    /// dwell-timer refire on the same URL doesn't thrash the indexer.
    private var recentlyIndexed: [String: Date] = [:]

    private init() {}

    /// Wires deletion mirroring and warms the store. Called once at launch.
    func activate() {
        guard !didActivate else { return }
        didActivate = true
        HistoryStore.deletionObserver = { [weak self] deletion in
            self?.handleDeletion(deletion)
        }
        Task { await self.refreshStats() }
    }

    // MARK: - Settings

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.recallEnabled)
    }

    var semanticEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.recallSemanticEnabled)
    }

    /// Zero-egress mode: the agent answers history questions with the
    /// on-device synthesizer instead of sending retrieved passages to a cloud
    /// model. See ``RecallAnswerEngine``.
    var localAnswerMode: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.recallLocalAnswerMode)
    }

    var dwellSeconds: Double {
        let stored = UserDefaults.standard.integer(forKey: PreferenceKey.recallDwellSeconds)
        return stored > 0 ? Double(stored) : 8
    }

    private var denylistHosts: [String] {
        Self.parseHostList(UserDefaults.standard.string(forKey: PreferenceKey.recallDenylist) ?? "")
    }

    /// True when a host should never be indexed — banking, health, webmail,
    /// or anything the user added. Matches the host and any subdomain.
    func isHostDenied(_ host: String) -> Bool {
        let normalized = RecallHost.normalize(host)
        guard !normalized.isEmpty else { return true }
        return denylistHosts.contains { normalized == $0 || normalized.hasSuffix("." + $0) }
    }

    // MARK: - Capture

    /// Hands a dwelled page to the indexer. Cheap to call: it gates on the
    /// enabled flag, the denylist, a content-length floor, and a short
    /// per-URL cooldown, then fans the work out to a detached task so neither
    /// chunking nor the SQLite write touches the main thread.
    func noteCapture(_ page: CapturedPage) {
        guard isEnabled else { return }
        guard !isHostDenied(page.host) else { return }
        guard page.wordCount >= 50 else { return }

        let key = page.url.absoluteString
        if let last = recentlyIndexed[key], page.capturedAt.timeIntervalSince(last) < 30 {
            return
        }
        recentlyIndexed[key] = page.capturedAt
        pruneCooldownIfNeeded()

        let useEmbeddings = semanticEnabled
        Task.detached(priority: .utility) {
            let chunks = RecallChunker.chunks(for: page.text)
            guard !chunks.isEmpty else { return }

            var chunkEmbeddings: [[Float]]?
            var pageEmbedding: [Float]?
            if useEmbeddings, let embedder = await RecallEmbedder.sharedIfAvailable() {
                chunkEmbeddings = await embedder.embed(chunks.map(\.text))
                if let first = chunkEmbeddings?.first {
                    pageEmbedding = RecallEmbedder.meanPool(chunkEmbeddings ?? [first])
                }
            }

            await RecallStore.shared.index(
                page,
                chunks: chunks,
                chunkEmbeddings: chunkEmbeddings,
                pageEmbedding: pageEmbedding
            )
        }
    }

    // MARK: - Search

    /// Runs a hybrid recall query. Parses temporal/host filters, embeds the
    /// keywords on-device (when semantic search is on), and asks the store for
    /// ranked passages. Everything here is local.
    func search(_ rawQuery: String, sinceDays: Int? = nil, limit: Int = 12, now: Date = Date()) async -> [RecallHit] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (sinceDays ?? 0) > 0 else { return [] }
        var plan = RecallQueryPlanner.parse(trimmed, now: now)
        if let sinceDays, sinceDays > 0 {
            // An explicit since_days from the model tightens (or sets) the
            // parsed date floor.
            let explicit = now.addingTimeInterval(-Double(sinceDays) * 86_400)
            plan.since = plan.since.map { max($0, explicit) } ?? explicit
        }

        var vector: [Float]?
        if semanticEnabled, plan.hasTextQuery, let embedder = await RecallEmbedder.sharedIfAvailable() {
            vector = await embedder.embed([plan.terms]).first
        }

        return await RecallStore.shared.search(plan, queryVector: vector, limit: limit)
    }

    /// Pages related to the one being viewed — proactive "you've read about
    /// this before" connections. Semantic-only; empty when embeddings are off.
    func relatedDocuments(to url: URL, limit: Int = 5) async -> [RecallDocument] {
        guard isEnabled, semanticEnabled else { return [] }
        return await RecallStore.shared.relatedDocuments(toURL: url, limit: limit)
    }

    func setStarred(_ url: URL, starred: Bool) {
        Task { await RecallStore.shared.setStarred(url: url, starred: starred) }
    }

    // MARK: - Maintenance

    func refreshStats() async {
        stats = await RecallStore.shared.stats()
        semanticReady = await RecallStore.shared.embeddedChunkCount() > 0
    }

    func clearIndex() {
        Task {
            await RecallStore.shared.delete(.all)
            await refreshStats()
        }
    }

    // MARK: - Deletion mirroring

    private func handleDeletion(_ deletion: HistoryDeletion) {
        Task {
            await RecallStore.shared.delete(deletion)
            await refreshStats()
        }
    }

    // MARK: - Helpers

    private func pruneCooldownIfNeeded() {
        guard recentlyIndexed.count > 256 else { return }
        let cutoff = Date().addingTimeInterval(-300)
        recentlyIndexed = recentlyIndexed.filter { $0.value > cutoff }
    }

    static func parseHostList(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { RecallHost.normalize($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}
