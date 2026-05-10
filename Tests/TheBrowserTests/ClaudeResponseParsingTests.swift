import Foundation
import Testing
@testable import TheBrowser

@Suite("Claude JSON response parsing")
struct ClaudeResponseParsingTests {
    @Test("Valid JSON with a result field returns the result")
    func validResultIsReturned() {
        let raw = #"{"result": "hello"}"#
        #expect(ClaudeJSONResponse.result(from: raw) == "hello")
    }

    @Test("Surrounding whitespace in result is trimmed")
    func resultIsTrimmed() {
        let raw = #"{"result": "  spaced out  \n"}"#
        #expect(ClaudeJSONResponse.result(from: raw) == "spaced out")
    }

    @Test("Empty result yields nil so caller falls back to raw stdout")
    func emptyResultReturnsNil() {
        #expect(ClaudeJSONResponse.result(from: #"{"result": ""}"#) == nil)
        #expect(ClaudeJSONResponse.result(from: #"{"result": "   "}"#) == nil)
    }

    @Test("Missing result key yields nil")
    func missingResultKeyReturnsNil() {
        #expect(ClaudeJSONResponse.result(from: #"{"other": "value"}"#) == nil)
    }

    @Test("Malformed JSON yields nil instead of throwing")
    func malformedJSONReturnsNil() {
        #expect(ClaudeJSONResponse.result(from: "not json") == nil)
        #expect(ClaudeJSONResponse.result(from: "") == nil)
        #expect(ClaudeJSONResponse.result(from: "{") == nil)
    }

    @Test("Extra fields in the JSON are ignored")
    func ignoresExtraFields() {
        let raw = #"{"result": "ok", "session_id": "abc", "cost_usd": 0.01}"#
        #expect(ClaudeJSONResponse.result(from: raw) == "ok")
    }
}
