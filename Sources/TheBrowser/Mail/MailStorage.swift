import Foundation

/// Local JSON persistence for the inbox stores. Mirrors the file-store
/// convention already used by `ChatSessionStore` / `ArtifactStore`: a small
/// folder under `~/.thebrowser/`. Everything is best-effort — a failed read
/// just yields the default, a failed write is swallowed, so the inbox keeps
/// working in memory even if the disk is unavailable.
enum MailStorage {
    static let root: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thebrowser", isDirectory: true)
            .appendingPathComponent("mail", isDirectory: true)
    }()

    /// Isolated working directory for the mail sub-agent's CLI subprocess, so
    /// it runs nowhere near the user's projects. Created on demand.
    static var agentWorkspacePath: String {
        let dir = root.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = root.appendingPathComponent(filename, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to filename: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: root.appendingPathComponent(filename, isDirectory: false), options: .atomic)
        } catch {
            #if DEBUG
            print("MailStorage: failed to save \(filename): \(error)")
            #endif
        }
    }
}

/// Pulls the first balanced JSON value (object or array) out of a fast-model
/// reply and decodes it. The mail sub-agent is asked to emit raw JSON, but
/// small models still wrap it in prose or ```json fences sometimes — this
/// recovers the payload either way, the same lenient spirit as
/// `NativeBrowserToolCall`'s parser.
enum MailJSON {
    /// Returns the substring of the first top-level `{…}` or `[…]` in `text`,
    /// balancing braces/brackets while respecting string literals.
    static func firstValue(in text: String) -> String? {
        let scalars = Array(text)
        guard let start = scalars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = scalars[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < scalars.count {
            let ch = scalars[index]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 {
                    return String(scalars[start...index])
                }
            }
            index += 1
        }
        return nil
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let json = firstValue(in: text), let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}

/// Best-effort natural-language → Date resolver for `mail_remind`. Covers the
/// common shapes deterministically ("tomorrow", "in 2 days", "next week",
/// "friday", "in 3 hours", "tonight") so we don't pay for a model round-trip
/// on the easy cases. Returns nil when it can't parse — the caller can then
/// fall back to the mail sub-agent.
enum NaturalDateParser {
    static func resolve(_ phrase: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // End-of-day anchor used by day-granularity phrases (5pm local).
        func endOfDay(_ date: Date) -> Date {
            calendar.date(bySettingHour: 17, minute: 0, second: 0, of: date) ?? date
        }

        if text == "today" || text == "later" || text == "eod" || text == "tonight" {
            let hour = text == "tonight" ? 20 : 17
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)
        }
        if text == "tomorrow" || text == "tmr" || text == "tmrw" {
            let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return endOfDay(next)
        }
        if text == "next week" {
            let next = calendar.date(byAdding: .day, value: 7, to: now) ?? now
            return endOfDay(next)
        }
        if text == "next month" {
            let next = calendar.date(byAdding: .month, value: 1, to: now) ?? now
            return endOfDay(next)
        }

        // "in N <unit>" / "N <unit>"
        if let relative = relativeOffset(text, now: now, calendar: calendar) {
            return relative
        }

        // Weekday names → the next occurrence.
        if let weekday = weekdayTarget(text, now: now, calendar: calendar) {
            return endOfDay(weekday)
        }

        return nil
    }

    private static func relativeOffset(_ text: String, now: Date, calendar: Calendar) -> Date? {
        // Matches "in 2 days", "3 hours", "in 1 week", "in 30 minutes".
        let pattern = #"(?:in\s+)?(\d+)\s*(minute|min|hour|hr|day|week|month)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Int(text[numberRange])
        else { return nil }

        let unit = String(text[unitRange])
        let component: Calendar.Component
        switch unit {
        case "minute", "min": component = .minute
        case "hour", "hr": component = .hour
        case "day": component = .day
        case "week": component = .weekOfYear
        case "month": component = .month
        default: return nil
        }
        return calendar.date(byAdding: component, value: amount, to: now)
    }

    private static func weekdayTarget(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let names: [String: Int] = [
            "sunday": 1, "sun": 1,
            "monday": 2, "mon": 2,
            "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4,
            "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
            "friday": 6, "fri": 6,
            "saturday": 7, "sat": 7
        ]
        let cleaned = text.replacingOccurrences(of: "next ", with: "").replacingOccurrences(of: "this ", with: "")
        guard let target = names[cleaned] else { return nil }
        let current = calendar.component(.weekday, from: now)
        var delta = target - current
        if delta <= 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: now)
    }
}
