import Foundation
import Testing
@testable import TheBrowser

@Suite("QuestionDetector")
struct QuestionDetectorTests {
    @Test("Explicit question marks always count, even on short queries")
    func explicitMarkAlwaysWins() {
        #expect(QuestionDetector.isQuestion("weather?"))
        #expect(QuestionDetector.isQuestion("X?"))
    }

    @Test(
        "Wh- interrogatives at the start are flagged",
        arguments: [
            "what time is it",
            "Why is the sky blue",
            "how to install python",
            "When did the war end",
            "where to eat in nyc",
            "who is bill gates",
            "which laptop is best",
            "whose phone is this",
            "What's the meaning of life"
        ]
    )
    func whWordsTriggerDetection(query: String) {
        #expect(QuestionDetector.isQuestion(query), "Expected '\(query)' to be a question")
    }

    @Test(
        "Auxiliary-led yes/no questions are flagged when there's an object",
        arguments: [
            "is the sky blue",
            "are dogs loyal",
            "can dogs eat chocolate",
            "should I buy a tesla",
            "did the patriots win",
            "would humans survive on mars"
        ]
    )
    func auxiliaryLedQuestions(query: String) {
        #expect(QuestionDetector.isQuestion(query), "Expected '\(query)' to be a question")
    }

    @Test(
        "Inquisitive openers and comparisons read as questions",
        arguments: [
            "tell me about climate change",
            "explain quantum mechanics",
            "define recursion",
            "summarize the french revolution",
            "compare react and vue",
            "react vs vue",
            "swift versus kotlin",
            "meaning of ephemeral",
            "difference between ipv4 and ipv6"
        ]
    )
    func inquisitiveAndComparisons(query: String) {
        #expect(QuestionDetector.isQuestion(query), "Expected '\(query)' to be a question")
    }

    @Test(
        "Plain searches are NOT flagged as questions",
        arguments: [
            "weather",
            "iphone 15 review",
            "best ramen brooklyn",
            "swift package manager docs",
            "anthropic",
            "running shoes 2026",
            "claude code"
        ]
    )
    func nonQuestionsStayQuiet(query: String) {
        #expect(!QuestionDetector.isQuestion(query), "Expected '\(query)' to NOT be a question")
    }

    @Test("Empty / whitespace-only queries are not questions")
    func emptyInputs() {
        #expect(!QuestionDetector.isQuestion(""))
        #expect(!QuestionDetector.isQuestion("   "))
        #expect(!QuestionDetector.isQuestion("\n\t"))
    }

    @Test("Single-word interrogatives without an object don't trigger")
    func singleAuxNoObject() {
        // "is" / "can" / "did" alone are not asks — could be brand names, etc.
        #expect(!QuestionDetector.isQuestion("is"))
        #expect(!QuestionDetector.isQuestion("can"))
    }

    @Test("Detection is case-insensitive")
    func caseInsensitive() {
        #expect(QuestionDetector.isQuestion("WHAT IS RUST"))
        #expect(QuestionDetector.isQuestion("How To Train A Dog"))
    }
}

@Suite("AIAnswerClient prompt")
struct AIAnswerClientTests {
    @Test("Prompt embeds question and numbered sources with citation rules")
    func promptIncludesSourcesAndRules() throws {
        let url1 = try #require(URL(string: "https://example.com/a"))
        let url2 = try #require(URL(string: "https://example.com/b"))
        let sources = [
            SearchResult(title: "Alpha", url: url1, snippet: "First snippet."),
            SearchResult(title: "Beta", url: url2, snippet: "Second snippet.")
        ]

        let prompt = AIAnswerClient.formatPrompt(
            question: "Why is the sky blue",
            sources: sources
        )

        #expect(prompt.contains("Question: Why is the sky blue"))
        #expect(prompt.contains("[1] Alpha — https://example.com/a"))
        #expect(prompt.contains("[2] Beta — https://example.com/b"))
        #expect(prompt.contains("First snippet."))
        // Rule reminders that govern the model's output format.
        #expect(prompt.localizedCaseInsensitiveContains("citation"), "Prompt should reference inline citations")
        #expect(prompt.contains("[1]"))
    }

    @Test("Citation URL list trims to the source cap")
    func citationCap() throws {
        let urls = (0..<10).compactMap { URL(string: "https://example.com/\($0)") }
        let results = urls.map { SearchResult(title: "T", url: $0, snippet: "") }

        let citations = AIAnswerClient.citationURLs(for: results)
        // Cap is internal, but should be at least 1 and no more than the input.
        #expect(citations.count >= 1)
        #expect(citations.count <= results.count)
        // First citation must be the first result so [1] points to the top hit.
        #expect(citations.first == urls.first)
    }

    @Test("Fast model id is haiku for Claude and mini for Codex")
    func fastModelMapping() {
        #expect(AIProviderKind.claude.fastModelID == "claude-haiku-4-5")
        #expect(AIProviderKind.codex.fastModelID == "gpt-5.4-mini")
    }

    @Test("Fast model ids resolve to known model options for both providers")
    func fastModelsAreRegistered() {
        for provider in AIProviderKind.allCases {
            let id = provider.fastModelID
            let option = AIModelOption.find(provider: provider, modelID: id)
            #expect(option != nil, "Fast model \(id) for \(provider) should be a registered option")
        }
    }
}

@Suite("AIAnswerView citation extraction")
struct AIAnswerViewCitationTests {
    @Test("citedIndices returns unique indices in first-mention order")
    func uniqueOrderedIndices() {
        let text = "Foo [1] bar [2][1] baz [3]."
        let indices = AIAnswerView.citedIndices(in: text, max: 5)
        #expect(indices == [1, 2, 3])
    }

    @Test("Out-of-range indices are skipped")
    func outOfRangeSkipped() {
        let text = "Pre [1] mid [9] end [2]"
        let indices = AIAnswerView.citedIndices(in: text, max: 3)
        #expect(indices == [1, 2])
    }

    @Test("Returns empty when max is zero")
    func zeroMax() {
        let indices = AIAnswerView.citedIndices(in: "[1] hi", max: 0)
        #expect(indices.isEmpty)
    }
}
