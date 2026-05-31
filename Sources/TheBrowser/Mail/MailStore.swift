import Foundation

/// Disk persistence for the intelligent-inbox subsystem. A thin JSON codec
/// over `~/.thebrowser/mail/` — one file per concern. The root is injectable
/// so tests can point it at a temp directory (mirrors `ChatSessionStore` /
/// `HistoryStore`). All reads return a sensible default on failure and all
/// writes are best-effort; nothing here throws across the UI boundary.
@MainActor
final class MailStore {
    let root: URL

    static let defaultRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".thebrowser/mail", isDirectory: true)

    init(root: URL = MailStore.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Isolated workspace for the sub-agent CLI subprocess so it never runs in
    /// the user's project directory.
    var agentWorkspaceURL: URL {
        let url = root.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum File {
        static let labels = "labels.json"
        static let decisions = "triage.json"
        static let examples = "triage_examples.json"
        static let memories = "memories.json"
        static let reminders = "reminders.json"
        static let voice = "voice_profile.json"
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Labels

    /// Loads labels, seeding the Slashy-style defaults on first run.
    func loadLabels() -> [AILabel] {
        if let labels: [AILabel] = read(File.labels), !labels.isEmpty {
            return labels
        }
        return AILabel.defaults
    }
    func saveLabels(_ labels: [AILabel]) { write(labels, to: File.labels) }

    // MARK: - Triage

    func loadDecisions() -> [TriageDecision] { read(File.decisions) ?? [] }
    func saveDecisions(_ decisions: [TriageDecision]) { write(decisions, to: File.decisions) }

    func loadExamples() -> [TriageExample] { read(File.examples) ?? [] }
    func saveExamples(_ examples: [TriageExample]) { write(examples, to: File.examples) }

    // MARK: - Memories

    func loadMemories() -> [MailMemory] { read(File.memories) ?? [] }
    func saveMemories(_ memories: [MailMemory]) { write(memories, to: File.memories) }

    // MARK: - Reminders

    func loadReminders() -> [MailReminder] { read(File.reminders) ?? [] }
    func saveReminders(_ reminders: [MailReminder]) { write(reminders, to: File.reminders) }

    // MARK: - Voice

    func loadVoice() -> VoiceProfile { read(File.voice) ?? .empty }
    func saveVoice(_ voice: VoiceProfile) { write(voice, to: File.voice) }

    // MARK: - JSON IO

    private func read<T: Decodable>(_ file: String) -> T? {
        let url = root.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(file), options: .atomic)
    }
}

// MARK: - Robust JSON extraction for small-model output

/// Extracts and decodes JSON from a fast model's reply, which may wrap the
/// payload in prose, markdown fences, or trailing commentary. We walk the text
/// to find the first balanced top-level `{…}` or `[…]` (tracking string
/// literals + escapes so braces inside quoted values don't fool the balance),
/// then decode that slice. Every method degrades to `nil` rather than throwing.
enum MailJSON {
    /// The first balanced top-level JSON object or array substring, or `nil`.
    static func firstValue(in text: String) -> String? {
        guard let openIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opener = text[openIndex]
        let closer: Character = opener == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false

        for index in text[openIndex...].indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == opener { depth += 1 }
            else if character == closer {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    return String(text[openIndex..<end])
                }
            }
        }
        return nil
    }

    /// Decodes `T` from a model reply, tolerating prose/fence wrapping.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let slice = firstValue(in: text), let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Text helpers

enum MailText {
    /// Strips quoted history, the "On … wrote:" attribution, forwarded blocks,
    /// and a trailing signature so a Sent message yields the user's own prose
    /// (the raw material for a voice profile and a cleaner reply context).
    static func stripQuotedReply(_ body: String) -> String {
        var kept: [String] = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Attribution line that precedes a quoted block — stop here.
            if trimmed.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if trimmed.hasPrefix("-----Original Message-----") { break }
            if trimmed.range(of: #"^From: .+"#, options: .regularExpression) != nil, kept.count > 1 { break }
            // Quoted line.
            if trimmed.hasPrefix(">") { continue }
            // Signature delimiter.
            if trimmed == "--" || trimmed == "-- " { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clamps text to a character budget, appending a notice when clipped.
    static func clip(_ text: String, max: Int) -> (text: String, clipped: Bool) {
        guard text.count > max else { return (text, false) }
        return (String(text.prefix(max)), true)
    }

    /// A coarse domain extraction from an email address.
    static func domain(of email: String) -> String? {
        guard let at = email.range(of: "@") else { return nil }
        let host = email[at.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        return host.isEmpty ? nil : host
    }
}

// MARK: - Natural-language dates (deterministic-first)

/// Resolves common reminder phrases to a concrete date relative to `now`,
/// without an LLM round-trip. Returns `nil` for anything it doesn't recognize,
/// letting the caller fall back to the model. Tuned for the everyday cases:
/// "tomorrow", "tonight", "in 3 days", "next monday", "friday", "next week".
enum NaturalDateParser {
    static func date(from phrase: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let startOfToday = calendar.startOfDay(for: now)
        func at(_ hour: Int, dayOffset: Int = 0, from base: Date = startOfToday) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: base) else { return nil }
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }

        // Relative keywords.
        if text == "tonight" { return at(18) }
        if text == "today" || text == "later today" { return now.addingTimeInterval(3 * 3600) }
        if text == "tomorrow" { return at(9, dayOffset: 1) }
        if text.contains("this weekend") {
            let weekday = calendar.component(.weekday, from: now) // 1=Sun…7=Sat
            let daysUntilSaturday = (7 - weekday + 7) % 7 == 0 ? 7 : (7 - weekday)
            return at(9, dayOffset: max(daysUntilSaturday, 0))
        }
        if text.contains("next week") { return nextWeekday(.monday, after: now, calendar: calendar, hour: 9) }

        // "in N hours/days/weeks" or "N hours/days" / "N days".
        if let m = firstMatch(#"in\s+(\d+)\s*(hour|hr|day|week)s?"#, in: text)
            ?? firstMatch(#"(\d+)\s*(hour|hr|day|week)s?"#, in: text),
           let n = Int(m.0) {
            switch m.1 {
            case "hour", "hr": return now.addingTimeInterval(Double(n) * 3600)
            case "day": return at(9, dayOffset: n)
            case "week": return at(9, dayOffset: n * 7)
            default: break
            }
        }

        // Weekday names, optionally prefixed with "next".
        let weekdays: [(String, Weekday)] = [
            ("monday", .monday), ("tuesday", .tuesday), ("wednesday", .wednesday),
            ("thursday", .thursday), ("friday", .friday), ("saturday", .saturday), ("sunday", .sunday)
        ]
        for (name, day) in weekdays where text.contains(name) {
            let forceNext = text.contains("next")
            return nextWeekday(day, after: now, calendar: calendar, hour: 9, skipToday: true, forceNextWeek: forceNext)
        }

        // Bare clock time "3pm" / "15:00" → today (or tomorrow if past).
        if let date = clockTime(in: text, now: now, calendar: calendar) { return date }

        return nil
    }

    private enum Weekday: Int { case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday }

    private static func nextWeekday(
        _ target: Weekday,
        after now: Date,
        calendar: Calendar,
        hour: Int,
        skipToday: Bool = false,
        forceNextWeek: Bool = false
    ) -> Date? {
        let current = calendar.component(.weekday, from: now)
        var delta = (target.rawValue - current + 7) % 7
        if delta == 0 && (skipToday || forceNextWeek) { delta = 7 }
        if forceNextWeek && delta < 7 { delta += 7 }
        let start = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: delta, to: start) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    private static func clockTime(in text: String, now: Date, calendar: Calendar) -> Date? {
        guard let m = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, in: text) else { return nil }
        guard var hour = Int(m.0) else { return nil }
        let minute = Int(m.1) ?? 0
        let meridiem = m.2
        if meridiem == "pm" && hour < 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return nil }
        let start = calendar.startOfDay(for: now)
        guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) else { return nil }
        return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    /// Returns the first regex match's first three capture groups as strings.
    private static func firstMatch(_ pattern: String, in text: String) -> (String, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> String {
            guard i < match.numberOfRanges, let r = Range(match.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
        return (group(1), group(2), group(3))
    }
}
