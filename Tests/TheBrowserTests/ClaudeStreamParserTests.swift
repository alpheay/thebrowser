import Foundation
import Testing
@testable import TheBrowser

@Suite("Claude stream-json parser")
struct ClaudeStreamParserTests {
    /// Thread-safe sink so the @Sendable onEvent closure can capture
    /// reference-type state from inside synchronous test bodies.
    final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [HarnessEvent] = []

        func append(_ event: HarnessEvent) {
            lock.lock(); defer { lock.unlock() }
            _events.append(event)
        }

        var events: [HarnessEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
    }

    private static func collect(_ feeds: [String]) -> ([HarnessEvent], ClaudeStreamParser) {
        let sink = EventSink()
        let parser = ClaudeStreamParser { event in
            sink.append(event)
        }
        for feed in feeds {
            parser.append(Data(feed.utf8))
        }
        return (sink.events, parser)
    }

    @Test("Emits one textDelta per content_block_delta line")
    func emitsTextDeltasPerLine() {
        let feed = [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"# + "\n",
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}}"# + "\n"
        ]
        let (events, _) = Self.collect(feed)

        // Should see two text-delta events in order.
        var deltas: [String] = []
        for event in events {
            if case .textDelta(let chunk) = event {
                deltas.append(chunk)
            }
        }
        #expect(deltas == ["Hi", " there"])
    }

    @Test("Buffers split lines until a newline arrives")
    func buffersPartialLines() {
        let firstHalf = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"#
        let secondHalf = #" world"}}}"# + "\n"

        let sink = EventSink()
        let parser = ClaudeStreamParser { event in sink.append(event) }
        parser.append(Data(firstHalf.utf8))
        // Nothing should fire — no newline yet.
        #expect(sink.events.isEmpty)
        parser.append(Data(secondHalf.utf8))

        var deltas: [String] = []
        for event in sink.events {
            if case .textDelta(let chunk) = event { deltas.append(chunk) }
        }
        #expect(deltas == ["Hello world"])
    }

    @Test("Final result event overrides accumulated text")
    func resultEventTakesPrecedence() {
        let feed = [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}}"# + "\n",
            #"{"type":"result","subtype":"success","result":"final canonical text"}"# + "\n"
        ]
        let (_, parser) = Self.collect(feed)
        #expect(parser.finalText == "final canonical text")
    }

    @Test("Falls back to accumulated text when no result event arrives")
    func accumulatedFallback() {
        let feed = [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"alpha "}}}"# + "\n",
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"beta"}}}"# + "\n"
        ]
        let (_, parser) = Self.collect(feed)
        #expect(parser.finalText == "alpha beta")
        #expect(parser.accumulatedText == "alpha beta")
    }

    @Test("Ignores unrelated event types (system, rate_limit, message_start, …)")
    func ignoresUnrelatedEvents() {
        let feed = [
            #"{"type":"system","subtype":"init","tools":[]}"# + "\n",
            #"{"type":"rate_limit_event","status":"allowed"}"# + "\n",
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}"# + "\n",
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"only this"}}}"# + "\n",
            #"{"type":"stream_event","event":{"type":"message_stop"}}"# + "\n"
        ]
        let (events, _) = Self.collect(feed)

        var deltas: [String] = []
        for event in events {
            if case .textDelta(let chunk) = event { deltas.append(chunk) }
        }
        #expect(deltas == ["only this"])
    }

    @Test("Assistant message backstop captures text if no result arrives")
    func assistantMessageBackstop() {
        let feed = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"from-assistant-block"}]}}"# + "\n"
        ]
        let (_, parser) = Self.collect(feed)
        #expect(parser.finalText == "from-assistant-block")
    }
}
