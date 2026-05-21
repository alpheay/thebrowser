import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func mailSearch(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let query = call.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        guard !query.isEmpty || mailbox != nil else {
            await openMailIntegration()
            return NativeBrowserToolResult(call: call, succeeded: false, content: "mail_search requires a query or mailbox.")
        }

        let maxResults = min(max(call.maxResults ?? 10, 1), 20)

        do {
            let summaries = try await searchMail(query, mailbox, maxResults)
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: NativeMailToolFormatter.searchResults(summaries, query: query, mailbox: mailbox)
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
        guard let identifier = call.mailIdentifier else {
            await openMailIntegration()
            return NativeBrowserToolResult(call: call, succeeded: false, content: "mail_read_thread requires a message_id or thread_id.")
        }

        do {
            let messages = try await readMailThread(identifier)
            await openMailIntegration()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: NativeMailToolFormatter.thread(messages, identifier: identifier)
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
}

private enum NativeMailToolFormatter {
    static func searchResults(_ summaries: [GmailMessageSummary], query: String, mailbox: GmailMailbox?) -> String {
        var lines: [String] = []
        lines.append("Mailbox: \(mailbox?.title ?? "All Mail")")
        lines.append("Query: \(query.isEmpty ? "(none)" : query)")

        guard !summaries.isEmpty else {
            lines.append("")
            lines.append("No matching mail found.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("Results:")
        for (index, summary) in summaries.enumerated() {
            lines.append("\(index + 1). \(summary.subject)")
            lines.append("From: \(summary.fromName.isEmpty ? summary.fromAddress : summary.fromName) <\(summary.fromAddress)>")
            lines.append("Date: \(formatted(summary.date))")
            lines.append("Message ID: \(summary.id)")
            lines.append("Thread ID: \(summary.threadId)")
            if !summary.snippet.isEmpty {
                lines.append("Snippet: \(summary.snippet)")
            }
            lines.append("")
        }

        lines.append("Use mail_read_thread with a Message ID or Thread ID to inspect a result before drafting.")
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func thread(_ messages: [GmailMessage], identifier: MailToolMessageIdentifier) -> String {
        var lines: [String] = []
        lines.append("Requested: \(identifier.displayValue)")

        guard !messages.isEmpty else {
            lines.append("No messages found in this thread.")
            return lines.joined(separator: "\n")
        }

        let subject = messages.last?.subject ?? messages.first?.subject ?? "(no subject)"
        lines.append("Subject: \(subject)")
        lines.append("Thread ID: \(messages.last?.threadId ?? messages.first?.threadId ?? "")")
        lines.append("Messages: \(messages.count)")

        for (index, message) in messages.enumerated() {
            lines.append("")
            lines.append("--- Message \(index + 1) ---")
            lines.append("Message ID: \(message.id)")
            lines.append("From: \(message.fromName.isEmpty ? message.fromAddress : message.fromName) <\(message.fromAddress)>")
            if !message.to.isEmpty {
                lines.append("To: \(message.to)")
            }
            if let cc = message.cc, !cc.isEmpty {
                lines.append("Cc: \(cc)")
            }
            lines.append("Date: \(formatted(message.date))")
            lines.append("Body:")
            let body = message.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(body.isEmpty ? "(No plain-text body.)" : String(body.prefix(8_000)))
        }

        return lines.joined(separator: "\n")
    }

    static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
