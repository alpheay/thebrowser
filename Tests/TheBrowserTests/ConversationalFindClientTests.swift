import Foundation
import Testing
@testable import TheBrowser

@Suite("ConversationalFindClient.sanitize")
struct ConversationalFindClientSanitizeTests {
    @Test("Plain phrase passes through unchanged")
    func plainPhrase() {
        #expect(ConversationalFindClient.sanitize("exponential backoff retry policy") == "exponential backoff retry policy")
    }

    @Test("Strips surrounding ASCII quotes")
    func stripsDoubleQuotes() {
        #expect(ConversationalFindClient.sanitize("\"retry semantics\"") == "retry semantics")
    }

    @Test("Strips surrounding smart quotes")
    func stripsSmartQuotes() {
        #expect(ConversationalFindClient.sanitize("\u{201C}retry semantics\u{201D}") == "retry semantics")
    }

    @Test("Strips Phrase: label prefix")
    func stripsLabelPrefix() {
        #expect(ConversationalFindClient.sanitize("Phrase: retry semantics") == "retry semantics")
        #expect(ConversationalFindClient.sanitize("Answer: exponential backoff") == "exponential backoff")
    }

    @Test("Preserves colons inside the actual phrase")
    func preservesInteriorColon() {
        // The colon here belongs to the page text, not a label prefix.
        #expect(ConversationalFindClient.sanitize("see also: retry policy") == "see also: retry policy")
    }

    @Test("Recognizes the NO_MATCH sentinel verbatim")
    func sentinelPassthrough() {
        let cleaned = ConversationalFindClient.sanitize(ConversationalFindClient.noMatchSentinel)
        #expect(cleaned == ConversationalFindClient.noMatchSentinel)
    }
}
