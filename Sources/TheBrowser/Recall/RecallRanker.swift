import Foundation

/// Blends *relevance* (how well a passage matches the query) with
/// *memorability* (how much the page mattered to the user) into one score.
/// This is what makes recall feel like remembering rather than grepping: the
/// article you read for 14 minutes and came back to twice outranks the one you
/// skimmed, at equal text relevance.
///
/// Pure functions, no I/O — unit-tested in `RecallRankerTests`.
enum RecallRanker {
    /// Reciprocal-rank-fusion constant. 60 is the value from the original RRF
    /// paper; it damps the gap between ranks 1 and 2 so a single lopsided
    /// signal can't dominate the fusion.
    static let rrfK = 60.0
    /// Recency half-life. A page read 30 days ago carries half the recency
    /// weight of one read today.
    static let recencyHalfLifeDays = 30.0

    struct Signals: Sendable, Equatable {
        /// 1-based position in the lexical (BM25) result list, or nil if the
        /// passage didn't surface lexically.
        var lexicalRank: Int?
        /// 1-based position in the semantic (vector) result list.
        var semanticRank: Int?
        var ageSeconds: Double
        /// Times the user dwelled on this page (capture count).
        var visitCount: Int
        var dwellSeconds: Double
        var starred: Bool
    }

    /// Reciprocal-rank fusion of the lexical and semantic rank lists. Robust
    /// to the two signals living on different score scales — we fuse *ranks*,
    /// not raw BM25/cosine numbers.
    static func fusion(lexicalRank: Int?, semanticRank: Int?) -> Double {
        var score = 0.0
        if let rank = lexicalRank { score += 1.0 / (rrfK + Double(rank)) }
        if let rank = semanticRank { score += 1.0 / (rrfK + Double(rank)) }
        return score
    }

    static func recencyMultiplier(ageSeconds: Double) -> Double {
        let ageDays = max(0, ageSeconds) / 86_400.0
        return pow(0.5, ageDays / recencyHalfLifeDays)
    }

    /// Engagement prior in [1, ~3]. Diminishing returns via `log1p` so a
    /// 40-minute read doesn't bury everything else, but real reading still
    /// wins over a bounce.
    static func engagementMultiplier(visitCount: Int, dwellSeconds: Double, starred: Bool) -> Double {
        let revisit = log1p(Double(max(0, visitCount - 1))) * 0.35
        let dwell = log1p(max(0, dwellSeconds) / 30.0) * 0.30
        let star = starred ? 0.75 : 0.0
        return 1.0 + revisit + dwell + star
    }

    static func score(_ signals: Signals) -> Double {
        let base = fusion(lexicalRank: signals.lexicalRank, semanticRank: signals.semanticRank)
        guard base > 0 else { return 0 }
        return base
            * recencyMultiplier(ageSeconds: signals.ageSeconds)
            * engagementMultiplier(
                visitCount: signals.visitCount,
                dwellSeconds: signals.dwellSeconds,
                starred: signals.starred
            )
    }

    /// Cosine similarity for the semantic ranker. Vectors are mean-pooled
    /// token embeddings; they aren't pre-normalized, so we divide by the norms.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
