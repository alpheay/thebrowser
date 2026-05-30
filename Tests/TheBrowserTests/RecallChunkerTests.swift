import Foundation
import Testing
@testable import TheBrowser

@Suite("RecallChunker")
struct RecallChunkerTests {
    @Test("Short paragraphs collapse into a single chunk")
    func mergesShortText() {
        let text = "First paragraph here.\n\nSecond short paragraph.\n\nThird one too."
        let chunks = RecallChunker.chunks(for: text)
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("First"))
        #expect(chunks[0].text.contains("Third"))
    }

    @Test("Empty or whitespace text yields no chunks")
    func emptyText() {
        #expect(RecallChunker.chunks(for: "").isEmpty)
        #expect(RecallChunker.chunks(for: "   \n\n  ").isEmpty)
    }

    @Test("A heading labels the following chunk")
    func headingLabel() {
        let body = String(repeating: "word ", count: 60)
        let text = "Introduction To Widgets\n\n\(body)"
        let chunks = RecallChunker.chunks(for: text)
        #expect(chunks.first?.heading == "Introduction To Widgets")
    }

    @Test("An over-long paragraph splits into multiple chunks")
    func splitsLongParagraph() {
        // ~600 words of full sentences, no paragraph breaks.
        let sentence = "This is a sentence about distributed systems and consensus. "
        let text = String(repeating: sentence, count: 60)
        let chunks = RecallChunker.chunks(for: text)
        #expect(chunks.count > 1)
        // No chunk wildly exceeds the budget.
        #expect(chunks.allSatisfy { $0.tokenCount <= RecallChunker.maxWords + 40 })
    }

    @Test("Ordinals are sequential from zero")
    func ordinals() {
        let sentence = "Lorem ipsum dolor sit amet consectetur adipiscing elit. "
        let text = String(repeating: sentence, count: 120)
        let chunks = RecallChunker.chunks(for: text)
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.ordinal == index)
        }
    }
}
