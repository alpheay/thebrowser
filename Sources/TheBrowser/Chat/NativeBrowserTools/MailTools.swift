import Foundation

// MARK: - Structured options

enum MailResultFormat: String, Sendable {
    case compact
    case detailed

    init(raw: String?) {
        guard let raw, let value = MailResultFormat(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            self = .compact
            return
        }
        self = value
    }

    var isDetailed: Bool { self == .detailed }
}

/// Structured search arguments handed to ``GmailStore.searchForTool``. The
/// executor builds one of these from the LLM's tool call so the store layer
/// doesn't need to know about Gmail's `q=` syntax — that translation happens
/// in ``gmailQueryString``.
struct MailSearchOptions: Sendable {
    var mailbox: GmailMailbox?
    var rawQuery: String?
    var from: String?
    var to: String?
    var subject: String?
    var keyword: String?
    var label: String?
    var hasAttachment: Bool?
    var unreadOnly: Bool?
    var starredOnly: Bool?
    var newerThan: String?
    var olderThan: String?
    var after: String?
    var before: String?
    var maxResults: Int
    var format: MailResultFormat

    /// True if any actual filter has been supplied — used to short-circuit
    /// the "you gave me nothing" guard in the executor.
    var hasAnyFilter: Bool {
        if mailbox != nil { return true }
        for value in [rawQuery, from, to, subject, keyword, label, newerThan, olderThan, after, before] {
            if value?.trimmedNonBlank != nil { return true }
        }
        if hasAttachment != nil || unreadOnly != nil || starredOnly != nil { return true }
        return false
    }

    /// Gmail query string assembled from the structured fields plus the
    /// free-text `query` escape hatch. Components are joined with spaces,
    /// which Gmail treats as logical AND.
    func gmailQueryString() -> String {
        var pieces: [String] = []
        if let value = rawQuery?.trimmedNonBlank { pieces.append(value) }
        if let value = from?.trimmedNonBlank { pieces.append("from:\(quoteIfNeeded(value))") }
        if let value = to?.trimmedNonBlank { pieces.append("to:\(quoteIfNeeded(value))") }
        if let value = subject?.trimmedNonBlank { pieces.append("subject:\(quoteIfNeeded(value))") }
        if let value = keyword?.trimmedNonBlank { pieces.append(quoteIfNeeded(value)) }
        if let value = label?.trimmedNonBlank { pieces.append("label:\(quoteIfNeeded(value))") }
        if hasAttachment == true { pieces.append("has:attachment") }
        if unreadOnly == true { pieces.append("is:unread") }
        if starredOnly == true { pieces.append("is:starred") }
        if let value = newerThan?.trimmedNonBlank, MailQueryDuration.isValid(value) {
            pieces.append("newer_than:\(value)")
        }
        if let value = olderThan?.trimmedNonBlank, MailQueryDuration.isValid(value) {
            pieces.append("older_than:\(value)")
        }
        if let value = MailQueryDate.gmailFormat(after?.trimmedNonBlank) {
            pieces.append("after:\(value)")
        }
        if let value = MailQueryDate.gmailFormat(before?.trimmedNonBlank) {
            pieces.append("before:\(value)")
        }
        return pieces.joined(separator: " ")
    }

    /// Short human-readable description of the active filters, used in the
    /// tool-result summary line so the LLM (and the user, in logs) can see
    /// what was actually searched.
    func filterSummary() -> String {
        var parts: [String] = []
        if let value = rawQuery?.trimmedNonBlank { parts.append("q:\(value)") }
        if let value = from?.trimmedNonBlank { parts.append("from:\(value)") }
        if let value = to?.trimmedNonBlank { parts.append("to:\(value)") }
        if let value = subject?.trimmedNonBlank { parts.append("subject:\(value)") }
        if let value = keyword?.trimmedNonBlank { parts.append("keyword:\(value)") }
        if let value = label?.trimmedNonBlank { parts.append("label:\(value)") }
        if hasAttachment == true { parts.append("has:attachment") }
        if unreadOnly == true { parts.append("unread") }
        if starredOnly == true { parts.append("starred") }
        if let value = newerThan?.trimmedNonBlank { parts.append("newer_than:\(value)") }
        if let value = olderThan?.trimmedNonBlank { parts.append("older_than:\(value)") }
        if let value = after?.trimmedNonBlank { parts.append("after:\(value)") }
        if let value = before?.trimmedNonBlank { parts.append("before:\(value)") }
        return parts.isEmpty ? "(none)" : parts.joined(separator: ", ")
    }

    /// Gmail's `q=` accepts bare tokens and quoted phrases. Wrap anything
    /// with whitespace so multi-word names like `"Alice Smith"` stay one
    /// token from Gmail's point of view.
    private func quoteIfNeeded(_ value: String) -> String {
        let needsQuote = value.contains(" ") || value.contains(",")
        if needsQuote {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }
}

extension String {
    /// Trim whitespace and return nil for the empty result. Used in the
    /// mail tool layer to flatten optional + blank into a single nil case.
    var trimmedNonBlank: String? {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

protocol MailSenderProviding {
    var fromName: String { get }
    var fromAddress: String { get }
}

extension MailSenderProviding {
    /// `"Name <addr>"` when both are present and distinct; otherwise just
    /// the address. The compact list relies on this to stay one column
    /// across mixed-quality `From` headers.
    var displaySender: String {
        let name = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == fromAddress {
            return fromAddress
        }
        return "\(name) <\(fromAddress)>"
    }
}

extension GmailMessageSummary: MailSenderProviding {}
extension GmailMessage: MailSenderProviding {}

/// Structured arguments for ``GmailStore.readForTool``. Supports either a
/// single identifier (the original `mail_read_thread` shape) or a batch of
/// identifiers so the agent can pull several threads in one call instead of
/// burning a turn per message.
struct MailReadOptions: Sendable {
    var identifiers: [MailToolMessageIdentifier]
    var includeBody: Bool
    var maxBodyChars: Int

    static let defaultBodyChars = 1500
    static let maxBatchSize = 5
}

private enum MailQueryDuration {
    /// Gmail accepts `<int><unit>` where unit is one of d/w/m/y. Anything
    /// else is dropped on the floor — the agent gets the raw piece back in
    /// the filter summary so it can correct the format on retry.
    static func isValid(_ value: String) -> Bool {
        let pattern = #"^\d+[dwmy]$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

private enum MailQueryDate {
    /// Gmail expects `YYYY/MM/DD` in `after:` / `before:`. The agent will
    /// usually emit ISO `YYYY-MM-DD`, so normalize both. Anything we can't
    /// parse is dropped so we never send malformed dates to the API.
    static func gmailFormat(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: "-/.")
        let parts = value.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1900...2200).contains(year),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return nil
        }
        return String(format: "%04d/%02d/%02d", year, month, day)
    }
}

// MARK: - Tool entry points

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func mailSearch(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let mailbox: GmailMailbox?
        if let rawMailbox = call.mailbox?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawMailbox.isEmpty {
            guard let parsed = GmailMailbox(rawValue: rawMailbox) else {
                await openMailIntegration()
                return NativeBrowserToolResult(
                    call: call,
                    succeeded: false,
                    content: "Unknown mailbox '\(rawMailbox)'. Use inbox, starred, sent, drafts, or all."
                )
            }
            mailbox = parsed
        } else {
            mailbox = nil
        }

        let options = MailSearchOptions(
            mailbox: mailbox,
            rawQuery: call.query,
            from: call.mailFrom,
            to: call.mailTo,
            subject: call.mailSubject,
            keyword: call.mailKeyword,
            label: call.mailLabel,
            hasAttachment: call.mailHasAttachment,
            unreadOnly: call.mailUnreadOnly,
            starredOnly: call.mailStarredOnly,
            newerThan: call.mailNewerThan,
            olderThan: call.mailOlderThan,
            after: call.mailAfter,
            before: call.mailBefore,
            maxResults: min(max(call.maxResults ?? 15, 1), 50),
            format: MailResultFormat(raw: call.mailFormat)
        )

        guard options.hasAnyFilter else {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "mail_search needs at least one filter (mailbox, from, keyword, newer_than, etc.). For \"what's in my inbox?\" pass mailbox=\"inbox\"."
            )
        }

        do {
            let summaries = try await searchMail(options)
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: NativeMailToolFormatter.searchResults(summaries, options: options)
            )
        } catch {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "Mail search failed: \(NativeMailToolFormatter.errorDescription(error))"
            )
        }
    }

    /// Dispatcher entry point — call via execute(_:).
    func mailReadThread(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let identifiers = call.mailIdentifiers
        guard !identifiers.isEmpty else {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "mail_read_thread needs a message_id, thread_id, message_ids, or thread_ids."
            )
        }
        guard identifiers.count <= MailReadOptions.maxBatchSize else {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "mail_read_thread accepts at most \(MailReadOptions.maxBatchSize) identifiers per call — got \(identifiers.count). Split into multiple calls."
            )
        }

        let options = MailReadOptions(
            identifiers: identifiers,
            includeBody: call.mailIncludeBody ?? true,
            maxBodyChars: clampedBodyChars(call.mailMaxBodyChars)
        )

        do {
            let threads = try await readMail(options)
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: NativeMailToolFormatter.threads(threads, options: options)
            )
        } catch {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "Mail thread read failed: \(NativeMailToolFormatter.errorDescription(error))"
            )
        }
    }

    /// Dispatcher entry point — call via execute(_:).
    func mailDraftReply(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let identifier = call.mailIdentifier else {
            await openMailIntegration()
            return NativeBrowserToolResult(call: call, succeeded: false, content: "mail_draft_reply requires a message_id or thread_id.")
        }
        let body = call.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else {
            await openMailIntegration()
            return NativeBrowserToolResult(call: call, succeeded: false, content: "mail_draft_reply requires a non-empty body.")
        }

        do {
            let target = try await draftMailReply(identifier, body)
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: """
                Opened Gmail with a reply draft.
                Replying to: \(target.fromName.isEmpty ? target.fromAddress : target.fromName) <\(target.fromAddress)>
                Subject: \(target.subject)
                Message ID: \(target.id)
                Thread ID: \(target.threadId)
                Status: Draft only; nothing was sent.
                """
            )
        } catch {
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "Mail reply draft failed: \(NativeMailToolFormatter.errorDescription(error))"
            )
        }
    }

    private func clampedBodyChars(_ raw: Int?) -> Int {
        let value = raw ?? MailReadOptions.defaultBodyChars
        return min(max(value, 200), 8_000)
    }
}

// MARK: - Formatter

private enum NativeMailToolFormatter {
    static func searchResults(_ summaries: [GmailMessageSummary], options: MailSearchOptions) -> String {
        let mailboxTitle = options.mailbox?.title ?? "All Mail"
        let filterText = options.filterSummary()
        let header = "Mailbox: \(mailboxTitle) · Filters: \(filterText) · Results: \(summaries.count)"

        guard !summaries.isEmpty else {
            return """
            \(header)

            No matching mail. Try widening the time range or relaxing a filter.
            """
        }

        var lines: [String] = [header, ""]
        let now = Date()
        switch options.format {
        case .detailed:
            for (index, summary) in summaries.enumerated() {
                let dateText = absoluteDate(summary.date)
                let badges = badgeString(summary)
                lines.append("[\(index + 1)] msg:\(summary.id) · thread:\(summary.threadId)")
                lines.append("    From: \(summary.displaySender)")
                lines.append("    Date: \(dateText)\(badges.isEmpty ? "" : " · \(badges)")")
                lines.append("    Subject: \(summary.subject)")
                if !summary.snippet.isEmpty {
                    lines.append("    Snippet: \(snippetPreview(summary.snippet, limit: 240))")
                }
                lines.append("")
            }
        case .compact:
            for (index, summary) in summaries.enumerated() {
                let dateText = compactDate(summary.date, now: now)
                let badges = badgeString(summary)
                let prefix = badges.isEmpty ? "  " : "\(badges) "
                lines.append("[\(index + 1)] \(prefix)\(dateText) · \(summary.displaySender) · \(truncate(summary.subject, limit: 80)) · msg:\(summary.id)")
            }
            lines.append("")
        }

        lines.append("Use mail_read_thread with msg:<id> or thread:<id> (or message_ids=[...]) to fetch full content. Pass format=\"detailed\" to mail_search for per-result snippets.")
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func threads(_ threads: [[GmailMessage]], options: MailReadOptions) -> String {
        guard !threads.isEmpty else {
            return "No messages found for the requested identifiers."
        }

        let summaries = zip(options.identifiers, threads).map { identifier, thread -> String in
            renderThread(identifier: identifier, messages: thread, options: options)
        }

        if summaries.count == 1 {
            return summaries[0]
        }

        var lines: [String] = []
        lines.append("Read \(summaries.count) threads.")
        lines.append("")
        for (index, body) in summaries.enumerated() {
            lines.append("═══ Thread \(index + 1) of \(summaries.count) ═══")
            lines.append(body)
            if index < summaries.count - 1 {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderThread(
        identifier: MailToolMessageIdentifier,
        messages: [GmailMessage],
        options: MailReadOptions
    ) -> String {
        var lines: [String] = []
        lines.append("Requested: \(identifier.displayValue)")

        guard !messages.isEmpty else {
            lines.append("No messages found in this thread.")
            return lines.joined(separator: "\n")
        }

        let anchor = messages.last ?? messages.first
        let subject = anchor?.subject ?? "(no subject)"
        let threadID = anchor?.threadId ?? ""
        lines.append("Thread: \(subject) (thread:\(threadID))")
        lines.append("Messages: \(messages.count)\(options.includeBody ? "" : " (headers only)")")

        for (index, message) in messages.enumerated() {
            lines.append("")
            lines.append("--- Message \(index + 1)/\(messages.count) ---")
            lines.append("msg:\(message.id) · \(absoluteDate(message.date))\(message.unread ? " · UNREAD" : "")")
            lines.append("From: \(message.displaySender)")
            if !message.to.isEmpty {
                lines.append("To: \(message.to)")
            }
            if let cc = message.cc, !cc.isEmpty {
                lines.append("Cc: \(cc)")
            }
            lines.append("Subject: \(message.subject)")

            if options.includeBody {
                let body = message.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("Body:")
                if body.isEmpty {
                    lines.append("(No plain-text body.)")
                } else {
                    let limited = String(body.prefix(options.maxBodyChars))
                    lines.append(limited)
                    if body.count > options.maxBodyChars {
                        lines.append("[…body truncated at \(options.maxBodyChars) chars — \(body.count - options.maxBodyChars) more chars available]")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Small helpers

    /// Tight flag string — at most a few characters, fixed-width per badge
    /// so the compact list stays scannable. Empty when the message is just
    /// a read, unstarred message.
    private static func badgeString(_ summary: GmailMessageSummary) -> String {
        var flags: [String] = []
        if summary.unread { flags.append("●") }
        if summary.starred { flags.append("★") }
        return flags.joined(separator: "")
    }

    private static func compactDate(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today " + timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yest. " + timeFormatter.string(from: date)
        }
        let interval = now.timeIntervalSince(date)
        if interval < 60 * 60 * 24 * 7 {
            return weekdayFormatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDayFormatter.string(from: date)
        }
        return shortYearFormatter.string(from: date)
    }

    private static func absoluteDate(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    private static func snippetPreview(_ snippet: String, limit: Int) -> String {
        let collapsed = snippet
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(collapsed, limit: limit)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let cut = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<cut]) + "…"
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    private static let shortYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
