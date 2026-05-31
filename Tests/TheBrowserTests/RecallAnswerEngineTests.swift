import Foundation
import Testing
@testable import TheBrowser

@Suite("RecallAnswerEngine")
struct RecallAnswerEngineTests {
    private func hit(_ id: Int64, _ title: String, _ snippet: String) -> RecallHit {
        RecallHit(
            id: id,
            url: URL(string: "https://example.com/\(id)")!,
            title: title,
            host: "example.com",
            heading: nil,
            snippet: snippet,
            lastVisitedAt: Date(),
            capturedAt: Date(),
            visitCount: 1,
            dwellSeconds: 0,
            starred: false,
            score: 1,
            lexicalScore: nil,
            semanticScore: nil
        )
    }

    @Test("Picks the query-relevant sentence and cites its page")
    func picksRelevantSentence() {
        let hits = [
            hit(1, "Attention explained",
                "The weather was nice. Transformers use self-attention to weigh tokens. Lunch followed."),
            hit(2, "Cooking blog",
                "We made pasta with garlic and olive oil for dinner.")
        ]
        let answer = RecallAnswerEngine.answer(query: "transformers self-attention", hits: hits)
        #expect(answer.summary.localizedCaseInsensitiveContains("self-attention"))
        #expect(answer.summary.localizedCaseInsensitiveContains("pasta") == false)
        #expect(answer.citations.contains { $0.id == 1 })
    }

    @Test("Always returns at least one citation when given hits")
    func alwaysCites() {
        let hits = [hit(7, "Some page", "Entirely unrelated prose about gardening tomatoes.")]
        let answer = RecallAnswerEngine.answer(query: "quantum computing", hits: hits)
        #expect(answer.citations.isEmpty == false)
        #expect(answer.summary.isEmpty == false)
    }

    @Test("Keyword extraction drops short tokens")
    func keywords() {
        let words = RecallAnswerEngine.keywords("On the GPU memory bandwidth")
        #expect(words.contains("gpu"))
        #expect(words.contains("memory"))
        #expect(words.contains("on") == false)
    }

    @Test("Sentence overlap scores keyword coverage")
    func overlap() {
        let terms = RecallAnswerEngine.keywords("memory bandwidth")
        let strong = RecallAnswerEngine.overlapScore("GPU memory bandwidth is the bottleneck", terms: terms)
        let weak = RecallAnswerEngine.overlapScore("the cat sat on the mat", terms: terms)
        #expect(strong > weak)
        #expect(weak == 0)
    }
}
