import Foundation

/// Parses a natural recall query into keywords plus structured filters.
///
/// People remember *when* and *where* as much as *what*: "that transformers
/// article last week", "the pricing page on stripe.com". Embeddings can't
/// represent "last week" — it's a date range — so we lift temporal and host
/// constraints out of the text and apply them as SQL filters, leaving clean
/// keywords for lexical + semantic matching. Pure and `now`-injectable so the
/// date math is unit-testable.
enum RecallQueryPlanner {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> RecallQuery {
        var working = " " + text.lowercased() + " "
        var since: Date?
        var until: Date?
        var host: String?

        // --- Host: site:domain, a bare domain token, or a known site name ---
        if let match = working.firstMatch(of: #/\bsite:\s*([a-z0-9.-]+\.[a-z]{2,})\b/#) {
            host = RecallHost.normalize(String(match.1))
            working.replaceSubrange(match.range, with: " ")
        } else if let match = working.firstMatch(of: #/\b(?:on|from|at)\s+([a-z0-9-]+\.[a-z]{2,}(?:\.[a-z]{2,})?)\b/#) {
            host = RecallHost.normalize(String(match.1))
            working.replaceSubrange(match.range, with: " ")
        } else {
            for (name, domain) in knownSites {
                if let range = working.range(of: " on \(name) ") ?? working.range(of: " from \(name) ") {
                    host = domain
                    working.replaceSubrange(range, with: " ")
                    break
                }
            }
        }

        // --- Temporal (first match wins; strip the matched phrase) ---
        if let (s, u, range) = matchTemporal(in: working, now: now, calendar: calendar) {
            since = s
            until = u
            working.replaceSubrange(range, with: " ")
        }

        let terms = cleanTerms(working)
        return RecallQuery(rawText: text, terms: terms, since: since, until: until, host: host)
    }

    // MARK: - Temporal matching

    private static func matchTemporal(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (Date?, Date?, Range<String.Index>)? {
        let startOfToday = calendar.startOfDay(for: now)

        // "last 3 days", "past 2 weeks", "3 months ago"
        if let match = text.firstMatch(of: #/\b(?:last|past)\s+(\d+)\s+(day|days|week|weeks|month|months)\b/#) {
            if let n = Int(match.1) {
                return (calendar.date(byAdding: unit(for: String(match.2)), value: -n, to: now), nil, match.range)
            }
        }
        if let match = text.firstMatch(of: #/\b(\d+)\s+(day|days|week|weeks|month|months)\s+ago\b/#) {
            if let n = Int(match.1) {
                return (calendar.date(byAdding: unit(for: String(match.2)), value: -n, to: now), nil, match.range)
            }
        }

        // Keyword windows.
        let keywords: [(String, () -> (Date?, Date?))] = [
            ("today", { (startOfToday, nil) }),
            ("yesterday", {
                let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)
                let end = calendar.date(byAdding: .second, value: -1, to: startOfToday)
                return (start, end)
            }),
            ("this week", { (calendar.date(byAdding: .day, value: -7, to: now), nil) }),
            ("last week", { (calendar.date(byAdding: .day, value: -7, to: now), nil) }),
            ("past week", { (calendar.date(byAdding: .day, value: -7, to: now), nil) }),
            ("this month", { (calendar.date(byAdding: .day, value: -31, to: now), nil) }),
            ("last month", { (calendar.date(byAdding: .day, value: -31, to: now), nil) }),
            ("past month", { (calendar.date(byAdding: .day, value: -31, to: now), nil) }),
            ("this year", { (calendar.date(byAdding: .day, value: -365, to: now), nil) }),
            ("last year", { (calendar.date(byAdding: .day, value: -365, to: now), nil) }),
            ("recently", { (calendar.date(byAdding: .day, value: -14, to: now), nil) }),
            ("lately", { (calendar.date(byAdding: .day, value: -14, to: now), nil) }),
            ("earlier today", { (startOfToday, nil) })
        ]
        for (phrase, compute) in keywords {
            if let range = text.range(of: " \(phrase) ") {
                let (s, u) = compute()
                // Keep one surrounding space so adjacent words stay separated.
                let stripRange = text.index(after: range.lowerBound)..<text.index(before: range.upperBound)
                return (s, u, stripRange)
            }
        }

        // Month names ("in march", "march 2024").
        if let result = matchMonth(in: text, now: now, calendar: calendar) {
            return result
        }

        // Weekday ("on tuesday") → that weekday's most recent past day.
        for (name, weekday) in weekdays {
            if let range = text.range(of: " \(name) ") {
                let day = mostRecentWeekday(weekday, before: now, calendar: calendar)
                let start = calendar.startOfDay(for: day)
                let end = calendar.date(byAdding: .second, value: -1, to: calendar.date(byAdding: .day, value: 1, to: start)!)
                let stripRange = text.index(after: range.lowerBound)..<text.index(before: range.upperBound)
                return (start, end, stripRange)
            }
        }

        return nil
    }

    private static func matchMonth(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (Date?, Date?, Range<String.Index>)? {
        for (name, month) in months {
            guard let range = text.range(of: " \(name) ") ?? text.range(of: " \(name),") else { continue }
            var year = calendar.component(.year, from: now)
            // Optional trailing year.
            let after = text[range.upperBound...]
            if let yearMatch = after.firstMatch(of: #/^\s*(\d{4})/#), let parsed = Int(yearMatch.1) {
                year = parsed
            } else if month > calendar.component(.month, from: now) {
                // "december" asked in January means last year.
                year -= 1
            }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            guard let start = calendar.date(from: components),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let end = calendar.date(byAdding: .second, value: -1, to: nextMonth)
            return (start, end, range)
        }
        return nil
    }

    private static func mostRecentWeekday(_ weekday: Int, before now: Date, calendar: Calendar) -> Date {
        let today = calendar.component(.weekday, from: now)
        var delta = today - weekday
        if delta <= 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: -delta, to: now) ?? now
    }

    private static func unit(for raw: String) -> Calendar.Component {
        if raw.hasPrefix("week") { return .weekOfYear }
        if raw.hasPrefix("month") { return .month }
        return .day
    }

    // MARK: - Terms cleanup

    private static func cleanTerms(_ text: String) -> String {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !stopwords.contains($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lexicons

    /// Pared to grammar/question/recall-meta words so real keywords survive.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "my",
        "me", "i", "that", "this", "it", "was", "were", "is", "are", "be",
        "did", "do", "does", "what", "whats", "which", "who", "when", "where",
        "about", "from", "with", "had", "have", "has", "you", "your", "we",
        "find", "show", "open", "again", "back", "saw", "seen", "read",
        "looking", "look", "some", "any", "at", "as", "by", "page", "site",
        "article", "thing", "stuff", "link", "earlier"
    ]

    private static let knownSites: [(String, String)] = [
        ("nytimes", "nytimes.com"), ("the verge", "theverge.com"),
        ("verge", "theverge.com"), ("github", "github.com"),
        ("youtube", "youtube.com"), ("wikipedia", "wikipedia.org"),
        ("reddit", "reddit.com"), ("hacker news", "news.ycombinator.com"),
        ("hackernews", "news.ycombinator.com"), ("arxiv", "arxiv.org"),
        ("stack overflow", "stackoverflow.com"), ("stackoverflow", "stackoverflow.com"),
        ("medium", "medium.com"), ("substack", "substack.com"),
        ("twitter", "x.com"), ("wsj", "wsj.com"), ("bloomberg", "bloomberg.com")
    ]

    private static let weekdays: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7)
    ]

    private static let months: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4),
        ("may", 5), ("june", 6), ("july", 7), ("august", 8),
        ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6),
        ("jul", 7), ("aug", 8), ("sep", 9), ("sept", 9), ("oct", 10),
        ("nov", 11), ("dec", 12)
    ]
}
