import Foundation
import Testing
@testable import TheBrowser

@Suite("RecallQueryPlanner")
struct RecallQueryPlannerTests {
    /// Fixed clock so the relative date math is deterministic: noon UTC on
    /// Friday, 29 May 2026.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 5, day: 29, hour: 12))!
    }

    @Test("Strips a relative-week phrase and keeps the keyword")
    func transformersLastWeek() {
        let plan = RecallQueryPlanner.parse("that transformers article I read last week", now: now, calendar: calendar)
        #expect(plan.terms == "transformers")
        #expect(plan.host == nil)
        #expect(plan.since == calendar.date(byAdding: .day, value: -7, to: now))
    }

    @Test("Extracts a bare domain host filter")
    func domainHost() {
        let plan = RecallQueryPlanner.parse("the pricing page on stripe.com", now: now, calendar: calendar)
        #expect(plan.host == "stripe.com")
        #expect(plan.terms == "pricing")
    }

    @Test("Parses site: syntax")
    func siteSyntax() {
        let plan = RecallQueryPlanner.parse("site:nytimes.com climate", now: now, calendar: calendar)
        #expect(plan.host == "nytimes.com")
        #expect(plan.terms == "climate")
    }

    @Test("Maps a known site name to its domain")
    func knownSite() {
        let plan = RecallQueryPlanner.parse("that thread on hacker news about rust", now: now, calendar: calendar)
        #expect(plan.host == "news.ycombinator.com")
        #expect(plan.terms.contains("rust"))
    }

    @Test("Yesterday yields a single-day window and no keywords")
    func yesterday() {
        let plan = RecallQueryPlanner.parse("what did I read yesterday", now: now, calendar: calendar)
        #expect(plan.hasTextQuery == false)
        let startOfToday = calendar.startOfDay(for: now)
        #expect(plan.since == calendar.date(byAdding: .day, value: -1, to: startOfToday))
        #expect(plan.until == calendar.date(byAdding: .second, value: -1, to: startOfToday))
    }

    @Test("Numeric windows: last N days / N days ago")
    func numericWindows() {
        let a = RecallQueryPlanner.parse("rust notes last 3 days", now: now, calendar: calendar)
        #expect(a.since == calendar.date(byAdding: .day, value: -3, to: now))

        let b = RecallQueryPlanner.parse("the post from 2 weeks ago", now: now, calendar: calendar)
        #expect(b.since == calendar.date(byAdding: .weekOfYear, value: -2, to: now))
    }

    @Test("Month name resolves to that month's range")
    func monthRange() {
        let plan = RecallQueryPlanner.parse("the budget I saw in march", now: now, calendar: calendar)
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        #expect(plan.since == start)
        #expect(plan.until != nil)
        // The end must fall inside March.
        if let until = plan.until {
            #expect(calendar.component(.month, from: until) == 3)
        }
    }

    @Test("A future-looking month rolls back to last year")
    func monthRollback() {
        let plan = RecallQueryPlanner.parse("notes from december", now: now, calendar: calendar)
        #expect(plan.since == calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)))
    }

    @Test("Stopwords and recall-meta words are removed from terms")
    func stopwords() {
        let plan = RecallQueryPlanner.parse("find that article about kubernetes operators", now: now, calendar: calendar)
        #expect(plan.terms == "kubernetes operators")
    }

    @Test("A pure keyword query carries no filters")
    func plainKeywords() {
        let plan = RecallQueryPlanner.parse("sqlite vector search", now: now, calendar: calendar)
        #expect(plan.terms == "sqlite vector search")
        #expect(plan.hasFilters == false)
    }
}
