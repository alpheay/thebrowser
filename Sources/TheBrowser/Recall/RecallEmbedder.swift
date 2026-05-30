import Foundation
import NaturalLanguage

/// On-device text embedder for semantic recall, built on Apple's
/// `NLContextualEmbedding` (NaturalLanguage). It runs entirely on the Mac, is
/// multilingual, and ships *with the OS* — no model to download, bundle, or
/// license, and not a single byte leaves the device. We mean-pool the
/// per-token contextual vectors into one passage vector; good enough for
/// recall@k, with a clean seam to swap in a Core ML bi-encoder later for more
/// quality.
///
/// An `actor` so the (non-`Sendable`) model handle is isolated and embedding
/// work stays off the main thread. `sharedIfAvailable()` returns nil when the
/// OS hasn't provisioned the embedding assets, in which case Recall degrades
/// to lexical-only search.
actor RecallEmbedder {
    static let shared = RecallEmbedder()

    private enum LoadState { case unloaded, available, unavailable }
    private var loadState: LoadState = .unloaded
    private var model: NLContextualEmbedding?
    private(set) var dimension = 0

    /// The shared embedder, or nil if on-device embeddings aren't available
    /// here. Result is effectively memoized via the internal load state.
    static func sharedIfAvailable() async -> RecallEmbedder? {
        await shared.ensureLoaded() ? shared : nil
    }

    /// Embeds each input into a fixed-width vector. Failed/empty inputs map to
    /// an empty vector (the index stores NULL and skips them in cosine).
    func embed(_ texts: [String]) -> [[Float]] {
        guard ensureLoaded(), let model else { return texts.map { _ in [] } }
        return texts.map { vector(for: $0, model: model) }
    }

    // MARK: - Loading

    @discardableResult
    private func ensureLoaded() -> Bool {
        switch loadState {
        case .available: return true
        case .unavailable: return false
        case .unloaded: break
        }

        guard let candidate = NLContextualEmbedding(language: .english) else {
            loadState = .unavailable
            return false
        }
        guard candidate.hasAvailableAssets else {
            // Assets aren't provisioned yet. Don't block a capture on a
            // download — degrade to lexical-only; a later launch picks them up.
            loadState = .unavailable
            return false
        }
        do {
            try candidate.load()
        } catch {
            loadState = .unavailable
            return false
        }
        model = candidate
        dimension = candidate.dimension
        loadState = .available
        return true
    }

    // MARK: - Embedding

    private func vector(for text: String, model: NLContextualEmbedding) -> [Float] {
        // Bound per-chunk cost: the head of a passage carries its topic.
        let trimmed = String(text.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let result = try? model.embeddingResult(for: trimmed, language: .english),
              dimension > 0 else {
            return []
        }

        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            guard vector.count == self.dimension else { return true }
            for i in 0..<self.dimension { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [] }
        return sum.map { Float($0 / Double(count)) }
    }

    // MARK: - Pooling

    /// Mean of several chunk vectors → one page vector (for "related pages").
    /// Pure; safe to call from anywhere.
    static func meanPool(_ vectors: [[Float]]) -> [Float] {
        let nonEmpty = vectors.filter { !$0.isEmpty }
        guard let dimension = nonEmpty.first?.count, dimension > 0 else { return [] }
        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        for vector in nonEmpty where vector.count == dimension {
            for i in 0..<dimension { sum[i] += vector[i] }
            count += 1
        }
        guard count > 0 else { return [] }
        return sum.map { $0 / Float(count) }
    }
}
