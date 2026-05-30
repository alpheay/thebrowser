import XCTest
@testable import TheBrowser
import Foundation

/// Unit coverage for the pure (non-UI, non-network) logic behind the
/// intelligent inbox: natural-language reminder parsing, lenient JSON
/// extraction from fast-model replies, label defaults, and tool-call parsing
/// for the new mail_* tools.
final class MailLogicTests: XCTestCase {

    // A fixed reference point so relative-date assertions are deterministic:
    // Wednesday, 2026-01-14 12:00:00 UTC.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 14
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - NaturalDateParser

    func testNaturalDateTomorrowIsNextDay() {
        let result = NaturalDateParser.resolve("tomorrow", now: now, calendar: utcCalendar)
        XCTAssertNotNil(result)
        let days = utcCalendar.dateComponents([.day], from: now, to: result!).day ?? 0
        XCTAssertEqual(days, 1)
    }

    func testNaturalDateInTwoDays() {
        let result = NaturalDateParser.resolve("in 2 days", now: now, calendar: utcCalendar)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, now)
        let days = utcCalendar.dateComponents([.day], from: now, to: result!).day ?? 0
        XCTAssertEqual(days, 2)
    }

    func testNaturalDateInThreeHours() {
        let result = NaturalDateParser.resolve("in 3 hours", now: now, calendar: utcCalendar)
        XCTAssertNotNil(result)
        let hours = utcCalendar.dateComponents([.hour], from: now, to: result!).hour ?? 0
        XCTAssertEqual(hours, 3)
    }

    func testNaturalDateWeekdayIsInFuture() {
        // From Wednesday, "friday" should resolve to the upcoming Friday.
        let result = NaturalDateParser.resolve("friday", now: now, calendar: utcCalendar)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, now)
        XCTAssertEqual(utcCalendar.component(.weekday, from: result!), 6) // Friday
    }

    func testNaturalDateNextWeekIsSevenDaysOut() {
        let result = NaturalDateParser.resolve("next week", now: now, calendar: utcCalendar)
        XCTAssertNotNil(result)
        let days = utcCalendar.dateComponents([.day], from: now, to: result!).day ?? 0
        XCTAssertEqual(days, 7)
    }

    func testNaturalDateGarbageReturnsNil() {
        XCTAssertNil(NaturalDateParser.resolve("whenever the stars align", now: now, calendar: utcCalendar))
        XCTAssertNil(NaturalDateParser.resolve("", now: now, calendar: utcCalendar))
    }

    // MARK: - MailJSON

    func testMailJSONExtractsFencedObject() {
        let text = """
        Sure, here you go:
        ```json
        {"query":"from:alex newer_than:7d"}
        ```
        """
        let decoded = MailJSON.decode(QueryProbe.self, from: text)
        XCTAssertEqual(decoded?.query, "from:alex newer_than:7d")
    }

    func testMailJSONExtractsArrayAmidProse() {
        let text = "Here are the labels: [{\"id\":\"1\",\"label\":\"important\"}] — hope that helps!"
        let json = MailJSON.firstValue(in: text)
        XCTAssertEqual(json, "[{\"id\":\"1\",\"label\":\"important\"}]")
    }

    func testMailJSONHandlesBracesInsideStrings() {
        // A closing brace inside a string literal must not end the object early.
        let text = #"{"body":"use {placeholder} here","subject":"hi"}"#
        let json = MailJSON.firstValue(in: text)
        XCTAssertEqual(json, text)
    }

    func testMailJSONReturnsNilWhenNoJSON() {
        XCTAssertNil(MailJSON.firstValue(in: "just plain prose, nothing structured"))
    }

    private struct QueryProbe: Decodable { let query: String }

    // MARK: - AILabel defaults

    func testDefaultLabelsCountAndDisabledOnes() {
        let defaults = AILabel.defaults
        XCTAssertEqual(defaults.count, 7)
        XCTAssertEqual(defaults.first { $0.id == "hiring" }?.enabled, false)
        XCTAssertEqual(defaults.first { $0.id == "investors" }?.enabled, false)
        XCTAssertEqual(defaults.first { $0.id == "important" }?.enabled, true)
    }

    // MARK: - Send mode

    func testSendModeDefaultIsDraftOnly() {
        XCTAssertEqual(MailSendMode(rawValue: "draftOnly"), .draftOnly)
        XCTAssertNil(MailSendMode(rawValue: "nonsense"))
    }

    // MARK: - Memory anchors

    func testMemoryAnchorDomainStripsAt() {
        XCTAssertEqual(MailMemoryAnchor.domain("Example.com").value, "example.com")
        XCTAssertEqual(MailMemoryAnchor.email("Alex@Example.com").value, "alex@example.com")
    }

    // MARK: - Tool-call parsing for the new mail tools

    func testParseMailDraft() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_draft","message_id":"m1","instructions":"say yes"}"#)
        XCTAssertEqual(call?.name, .mailDraft)
        XCTAssertEqual(call?.messageID, "m1")
        XCTAssertEqual(call?.instructions, "say yes")
    }

    func testParseMailDraftRequiresTarget() {
        // No thread/message and no recipient → invalid.
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_draft","instructions":"hi"}"#)
        XCTAssertNil(call)
    }

    func testParseMailSend() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_send","to":"a@b.com","subject":"Hi","body":"hello"}"#)
        XCTAssertEqual(call?.name, .mailSend)
        XCTAssertEqual(call?.to, "a@b.com")
        XCTAssertEqual(call?.body, "hello")
    }

    func testParseMailModifyWithArray() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_modify","message_ids":["a","b"],"archive":true}"#)
        XCTAssertEqual(call?.name, .mailModify)
        XCTAssertEqual(call?.resolvedMessageIDs, ["a", "b"])
        XCTAssertEqual(call?.archive, true)
    }

    func testParseMailModifyTolueratesCommaString() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_modify","message_ids":"a, b, c","star":true}"#)
        XCTAssertEqual(call?.resolvedMessageIDs, ["a", "b", "c"])
        XCTAssertEqual(call?.star, true)
    }

    func testParseMailRemind() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_remind","thread_id":"t1","when":"in 2 days"}"#)
        XCTAssertEqual(call?.name, .mailRemind)
        XCTAssertEqual(call?.threadID, "t1")
        XCTAssertEqual(call?.when, "in 2 days")
    }

    func testParseMailRemindRequiresWhen() {
        XCTAssertNil(NativeBrowserToolCall.parse(from: #"{"tool":"mail_remind","thread_id":"t1"}"#))
    }

    func testParseMailTriageDefaultsValid() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_triage","scope":"new"}"#)
        XCTAssertEqual(call?.name, .mailTriage)
        XCTAssertEqual(call?.scope, "new")
    }

    func testParseMailMemoryAdd() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_memory","action":"add","text":"likes mornings","anchor":"a@b.com"}"#)
        XCTAssertEqual(call?.name, .mailMemory)
        XCTAssertEqual(call?.action, "add")
        XCTAssertEqual(call?.anchor, "a@b.com")
    }

    func testParseMailSearchBareIsValid() {
        // A bare mail_search (no query, no mailbox) is now valid — lists inbox.
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_search"}"#)
        XCTAssertEqual(call?.name, .mailSearch)
    }

    func testParseMailSearchNaturalLanguageFlag() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_search","query":"invoices from finance","natural_language":true}"#)
        XCTAssertEqual(call?.naturalLanguage, true)
        XCTAssertEqual(call?.query, "invoices from finance")
    }

    func testParseMailShow() {
        let call = NativeBrowserToolCall.parse(from: #"{"tool":"mail_show","mailbox":"starred"}"#)
        XCTAssertEqual(call?.name, .mailShow)
        XCTAssertEqual(call?.mailbox, "starred")
    }

    // MARK: - Direct slash-command parsing

    func testDirectMailDraftCommand() {
        let call = DirectNativeToolCommand.parse("/mail_draft message:m1 | decline politely")
        XCTAssertEqual(call?.name, .mailDraft)
        XCTAssertEqual(call?.messageID, "m1")
        XCTAssertEqual(call?.instructions, "decline politely")
    }

    func testDirectMailShowCommand() {
        let call = DirectNativeToolCommand.parse("/mail_show sent")
        XCTAssertEqual(call?.name, .mailShow)
        XCTAssertEqual(call?.mailbox, "sent")
    }
}
