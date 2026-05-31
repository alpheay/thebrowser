import Foundation
import Testing
@testable import TheBrowser

@Suite("RecallRanker")
struct RecallRankerTests {
    @Test("Fusion rewards appearing in both rank lists")
    func fusionCombines() {
        let lexicalOnly = RecallRanker.fusion(lexicalRank: 1, semanticRank: nil)
        let both = RecallRanker.fusion(lexicalRank: 1, semanticRank: 1)
        #expect(both > lexicalOnly)
        #expect(RecallRanker.fusion(lexicalRank: nil, semanticRank: nil) == 0)
    }

    @Test("Higher (worse) ranks fuse to a lower score")
    func fusionMonotonic() {
        #expect(RecallRanker.fusion(lexicalRank: 1, semanticRank: nil)
                > RecallRanker.fusion(lexicalRank: 5, semanticRank: nil))
    }

    @Test("Recency halves at the half-life")
    func recencyHalfLife() {
        #expect(abs(RecallRanker.recencyMultiplier(ageSeconds: 0) - 1.0) < 1e-9)
        let halfLife = RecallRanker.recencyHalfLifeDays * 86_400
        #expect(abs(RecallRanker.recencyMultiplier(ageSeconds: halfLife) - 0.5) < 1e-9)
    }

    @Test("Engagement is neutral for a single bounce, higher for a read")
    func engagement() {
        let bounce = RecallRanker.engagementMultiplier(visitCount: 1, dwellSeconds: 0, starred: false)
        #expect(abs(bounce - 1.0) < 1e-9)
        let read = RecallRanker.engagementMultiplier(visitCount: 3, dwellSeconds: 600, starred: false)
        #expect(read > bounce)
        let starred = RecallRanker.engagementMultiplier(visitCount: 1, dwellSeconds: 0, starred: true)
        #expect(starred > bounce)
    }

    @Test("A read, revisited, recent page outranks a skimmed old one at equal relevance")
    func memorabilityOrdering() {
        let strong = RecallRanker.score(.init(
            lexicalRank: 1, semanticRank: 1, ageSeconds: 86_400,
            visitCount: 4, dwellSeconds: 900, starred: true
        ))
        let weak = RecallRanker.score(.init(
            lexicalRank: 1, semanticRank: 1, ageSeconds: 120 * 86_400,
            visitCount: 1, dwellSeconds: 3, starred: false
        ))
        #expect(strong > weak)
    }

    @Test("Cosine similarity: identical is 1, orthogonal is 0")
    func cosine() {
        #expect(abs(RecallRanker.cosineSimilarity([1, 2, 3], [1, 2, 3]) - 1.0) < 1e-9)
        #expect(abs(RecallRanker.cosineSimilarity([1, 0], [0, 1])) < 1e-9)
        #expect(RecallRanker.cosineSimilarity([], []) == 0)
        #expect(RecallRanker.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
    }
}
