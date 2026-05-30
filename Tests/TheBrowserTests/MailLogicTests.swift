import Foundation
import Testing
@testable import TheBrowser

@Suite("Mail JSON extraction")
struct MailJSONTests {
    @Test("Extracts a JSON object wrapped in prose and a code fence")
    func extractsFencedObject() throws {
        let text = "Sure, here you go:\n```json\n{\"subject\":\"Hi\",\"body\":\"There you go\"}\n```\nLet me know!"
        let content = try #require(MailJSON.decode(DraftContent.self, from: text))
        #expect(content.subject == "Hi")
        #expect(content.body == "There you go")
    }

    @Test("Extracts a top-level JSON array")
    func extractsArray() throws {
        let text = "Result: [{\"messageID\":\"m1\",\"label\":\"Important\",\"confidence\":0.9}] done"
        let decisions = try #require(MailJSON.decode([TriageDecision].self, from: text))
        #expect(decisions.count == 1)
        #expect(decisions.first?.label == "Important")
    }

    @Test("Braces inside string literals don't fool the balancer")
    func handlesBracesInStrings() throws {
        let text = "{\"body\":\"use {curly} braces { here }\"}"
        let content = try #require(MailJSON.decode(DraftContent.self, from: text))
        #expect(content.body == "use {curly} braces { here }")
    }

    @Test("Returns nil when there's no JSON")
    func returnsNilWithoutJSON() {
        #expect(MailJSON.decode(DraftContent.self, from: "no json at all") == nil)
    }
}

@Suite("Natural-language dates")
struct NaturalDateParserTests {
    private let now = Date(timeIntervalSince1970: 1_716_000_000) // fixed reference
    private let cal = Calendar.current

    @Test("tomorrow resolves to the next day at 9am")
    func tomorrow() throws {
        let date = try #require(NaturalDateParser.date(from: "tomorrow", now: now, calendar: cal))
        let expectedDay = cal.date(byAdding: .day, value: 1, to: now)!
        #expect(cal.isDate(date, inSameDayAs: expectedDay))
        #expect(cal.component(.hour, from: date) == 9)
    }

    @Test("tonight resolves to 6pm today")
    func tonight() throws {
        let date = try #require(NaturalDateParser.date(from: "tonight", now: now, calendar: cal))
        #expect(cal.isDate(date, inSameDayAs: now))
        #expect(cal.component(.hour, from: date) == 18)
    }

    @Test("in 3 days adds three days")
    func inThreeDays() throws {
        let date = try #require(NaturalDateParser.date(from: "in 3 days", now: now, calendar: cal))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day
        #expect(days == 3)
    }

    @Test("a weekday name resolves to that weekday in the future")
    func weekday() throws {
        let date = try #require(NaturalDateParser.date(from: "next monday", now: now, calendar: cal))
        #expect(cal.component(.weekday, from: date) == 2) // Monday
        #expect(date > now)
    }

    @Test("unparseable phrases return nil")
    func unparseable() {
        #expect(NaturalDateParser.date(from: "whenever you feel like it", now: now, calendar: cal) == nil)
    }
}

@Suite("Mail text helpers")
struct MailTextTests {
    @Test("Strips quoted history and the attribution line")
    func stripsQuotedReply() {
        let body = """
        Sounds great, let's do Thursday.

        On Mon, Jan 1, 2026 at 9:00 AM, Alex <alex@x.com> wrote:
        > Are you free this week?
        > Let me know.
        """
        let stripped = MailText.stripQuotedReply(body)
        #expect(stripped == "Sounds great, let's do Thursday.")
    }

    @Test("Extracts the domain from an address")
    func domain() {
        #expect(MailText.domain(of: "sam@acme.com") == "acme.com")
        #expect(MailText.domain(of: "not-an-email") == nil)
    }
}

@Suite("Memory anchors")
struct MailMemoryAnchorTests {
    @Test("Parses and round-trips anchor strings", arguments: [
        ("always", "always"),
        ("email:Foo@Bar.com", "email:foo@bar.com"),
        ("domain:Acme.com", "domain:acme.com"),
        ("activity:Scheduling", "activity:scheduling")
    ])
    func roundTrip(_ input: String, _ expected: String) {
        #expect(MailMemoryAnchor.parse(input).stringValue == expected)
    }

    @Test("email and domain anchors match the right recipients")
    func applies() {
        #expect(MailMemoryAnchor.email("a@b.com").stringValue == "email:a@b.com")
        let emailMemory = MailMemory(text: "x", anchor: .email("a@b.com"))
        #expect(emailMemory.applies(toEmail: "a@b.com"))
        #expect(!emailMemory.applies(toEmail: "c@b.com"))
        let domainMemory = MailMemory(text: "y", anchor: .domain("b.com"))
        #expect(domainMemory.applies(toEmail: "anyone@b.com"))
        #expect(!domainMemory.applies(toEmail: "anyone@other.com"))
        #expect(MailMemory(text: "z", anchor: .always).applies(toEmail: nil))
    }
}

@Suite("AI labels")
struct AILabelTests {
    @Test("Defaults include the Slashy-style set with Hiring/Investors disabled")
    func defaults() {
        let names = AILabel.defaults.map(\.name)
        #expect(names.contains("Important"))
        #expect(names.contains("Newsletter"))
        #expect(AILabel.defaults.first(where: { $0.name == "Investors" })?.enabled == false)
        #expect(AILabel.defaults.first(where: { $0.name == "Important" })?.enabled == true)
    }

    @Test("Deterministic filters match sender and subject")
    func deterministicMatch() {
        let billing = AILabel(name: "Billing", descriptionText: "", colorHex: "8FCB9B", subjectFilters: ["receipt", "invoice"])
        #expect(billing.deterministicMatch(fromAddress: "store@shop.com", subject: "Your receipt is ready"))
        #expect(!billing.deterministicMatch(fromAddress: "a@b.com", subject: "lunch?"))
    }
}

@MainActor
@Suite("Mail store + model")
struct MailStoreModelTests {
    private func makeStore() -> (MailStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailtest-\(UUID().uuidString)")
        return (MailStore(root: dir), dir)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mailtest-\(UUID().uuidString)")!
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    @Test("Round-trips memories and reminders through disk")
    func persistenceRoundTrip() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        let memories = [MailMemory(text: "Prefers afternoons", anchor: .email("a@b.com"))]
        store.saveMemories(memories)
        store.saveReminders([MailReminder(threadId: "t1", subject: "Hi", fireAt: Date())])

        let reloaded = MailStore(root: dir)
        #expect(reloaded.loadMemories().first?.text == "Prefers afternoons")
        #expect(reloaded.loadMemories().first?.anchor.stringValue == "email:a@b.com")
        #expect(reloaded.loadReminders().first?.threadId == "t1")
    }

    @Test("Fresh labels seed the defaults")
    func seedsDefaults() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        #expect(store.loadLabels().count == AILabel.defaults.count)
    }

    @Test("Dropped-ball scan skips user-replied, automated, and recent threads")
    func droppedBallHeuristic() {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        let model = MailModel(store: store, defaults: makeDefaults())
        let now = Date()
        let old = now.addingTimeInterval(-6 * 86_400)
        func summary(_ id: String, thread: String, from: String, date: Date) -> GmailMessageSummary {
            GmailMessageSummary(id: id, threadId: thread, snippet: "", subject: "Re: \(thread)", fromName: from, fromAddress: from, date: date, unread: false, starred: false, labelIDs: [])
        }
        let summaries = [
            summary("a", thread: "t1", from: "me@x.com", date: old),       // user replied last → skip
            summary("b", thread: "t2", from: "boss@y.com", date: old),     // real, old → flag
            summary("c", thread: "t3", from: "noreply@z.com", date: old),  // automated → skip
            summary("d", thread: "t4", from: "friend@y.com", date: now)    // too recent → skip
        ]
        let created = model.scanDroppedBalls(in: summaries, accountEmail: "me@x.com", days: 3, now: now)
        #expect(created.count == 1)
        #expect(created.first?.threadId == "t2")
    }

    @Test("Draft-only send mode stages instead of sending")
    func draftOnlyStages() async {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        let model = MailModel(store: store, defaults: makeDefaults())
        let draft = MailDraftPreview(to: "a@b.com", subject: "Hi", body: "Hello")
        let result = await model.send(draft, gmail: GmailStore(), userInitiated: false)
        #expect(result == .stagedForReview(draftID: draft.id))
        #expect(model.pendingDrafts.contains { $0.id == draft.id })
    }
}
