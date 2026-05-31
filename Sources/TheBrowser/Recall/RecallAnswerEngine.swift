import Foundation

/// A synthesized, cited answer assembled entirely on-device.
struct RecallAnswer: Sendable, Equatable {
    var summary: String
    var citations: [RecallCitation]
}

struct RecallCitation: Sendable, Equatable, Identifiable {
    var id: Int64
    var title: String
    var url: URL
    var lastVisitedAt: Date
}

/// Zero-egress answer synthesis. Given a query and the locally-retrieved
/// passages, it stitches the most query-relevant sentences into a short, cited
/// answer **without any model call** — nothing leaves the Mac. It's extractive
/// rather than generative, so it won't paraphrase, but it's honest ("here is
/// what you actually read, and where") and instant.
///
/// The signature is the seam for a future generative backend: a local MLX or
/// Foundation Models summarizer can implement the same `answer(query:hits:)`
/// shape and slot in behind the same local-answer toggle, still on-device.
enum RecallAnswerEngine {
    static func answer(query: String, hits: [RecallHit]) -> RecallAnswer {
        let terms = keywords(query)
        let top = Array(hits.prefix(4))

        struct Candidate { var sentence: String; var score: Double; var hit: RecallHit; var order: Int }
        var candidates: [Candidate] = []
        for (hitIndex, hit) in top.enumerated() {
            let sentences = splitSentences(hit.snippet)
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let base = overlapScore(sentence, terms: terms)
                guard base > 0 else { continue }
                // Nudge by the page's own rank so a sentence from the best
                // page edges out an equally-matching one from a weaker page.
                let rankBoost = Double(top.count - hitIndex) * 0.1
                candidates.append(Candidate(
                    sentence: sentence,
                    score: base + rankBoost,
                    hit: hit,
                    order: hitIndex * 1_000 + sentenceIndex
                ))
            }
        }

        let best = candidates.sorted { $0.score > $1.score }.prefix(3)
        let ordered = best.sorted { $0.order < $1.order }
        var summary = ordered.map(\.sentence).joined(separator: " ")
        if summary.isEmpty { summary = top.first?.snippet ?? "" }
        summary = clamp(summary, to: 600)

        var usedHits: [RecallHit] = []
        for candidate in ordered where !usedHits.contains(where: { $0.id == candidate.hit.id }) {
            usedHits.append(candidate.hit)
        }
        if usedHits.isEmpty { usedHits = Array(top.prefix(2)) }
        let citations = usedHits.prefix(3).map {
            RecallCitation(id: $0.id, title: $0.displayTitle, url: $0.url, lastVisitedAt: $0.lastVisitedAt)
        }

        return RecallAnswer(summary: summary, citations: Array(citations))
    }

    // MARK: - Helpers

    static func keywords(_ query: String) -> Set<String> {
        Set(
            query
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    static func overlapScore(_ sentence: String, terms: Set<String>) -> Double {
        guard !terms.isEmpty else { return 0 }
        let words = sentence
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        let hits = words.reduce(into: 0) { count, word in
            if terms.contains(word) { count += 1 }
        }
        guard hits > 0 else { return 0 }
        // Reward coverage, lightly penalize very long sentences.
        let lengthPenalty = 1.0 / (1.0 + Double(max(0, words.count - 30)) / 40.0)
        return Double(hits) * lengthPenalty
    }

    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 1 { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 1 { sentences.append(tail) }
        return sentences
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
