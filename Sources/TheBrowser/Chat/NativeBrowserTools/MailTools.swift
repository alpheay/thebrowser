import Foundation

/// Executes every `mail_*` tool the assistant can call. One `@MainActor`
/// service that owns references to the Gmail data layer (`GmailStore`) and the
/// intelligent-inbox coordinator (`MailModel`), so all mail logic lives in one
/// place instead of being smeared across a dozen executor closures.
///
/// Design notes that fix the old tools' flaws:
///  - Results are STRUCTURED: a compact JSON block the fast model parses
///    deterministically, plus a one-line human summary. No brittle prose.
///  - Reads are SILENT by default — they never force the Gmail overlay open.
///    The explicit `mail_show` tool is the only one that pops the UI.
///  - `mail_search` paginates (no hard 20-cap) and never silently truncates.
///  - `mail_read_thread` surfaces attachments and only clips bodies when asked,
///    and says so when it does.
@MainActor
final class MailToolService {
    private let gmail: GmailStore
    private let mail: MailModel
    private let openOverlay: () -> Void

    init(gmail: GmailStore, mail: MailModel, openOverlay: @escaping () -> Void) {
        self.gmail = gmail
        self.mail = mail
        self.openOverlay = openOverlay
    }

    /// Entry point wired into `NativeBrowserToolExecutor.runMailTool`.
    func handle(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        switch call.name {
        case .mailSearch: return await search(call)
        case .mailReadThread: return await readThread(call)
        case .mailShow: return await show(call)
        case .mailModify: return await modify(call)
        case .mailDraft: return await draft(call)
        case .mailSend: return await send(call)
        case .mailTriage: return await triage(call)
        case .mailRemind: return await remind(call)
        case .mailMemory: return await memory(call)
        default:
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Unsupported mail tool: \(call.name.rawValue).")
        }
    }

    // MARK: - Search

    private func search(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let rawQuery = call.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mailbox = parseMailbox(call.mailbox)
        if call.mailbox != nil && mailbox == nil {
            return fail(call, "Unknown mailbox '\(call.mailbox!)'. Use inbox, starred, sent, drafts, or all.")
        }
        let maxResults = min(max(call.maxResults ?? 25, 1), 50)

        // Natural-language search: translate to Gmail operators on the fast model.
        var effectiveQuery = rawQuery
        var translated: String?
        if call.naturalLanguage == true, !rawQuery.isEmpty {
            translated = await mail.agent.translateQuery(rawQuery, today: Self.todayString())
            if let translated, !translated.isEmpty { effectiveQuery = translated }
        }

        do {
            let result = try await gmail.searchPaged(
                query: effectiveQuery,
                mailbox: mailbox,
                maxResults: maxResults,
                pageToken: call.pageToken
            )
            var hits = result.summaries.map { hit(from: $0) }

            // Natural-language: rerank by relevance to the original ask.
            if call.naturalLanguage == true, !rawQuery.isEmpty, hits.count > 1 {
                let order = await mail.agent.rerank(rawQuery, hits: hits)
                let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })
                hits = order.compactMap { byID[$0] }
            }

            let summaryLine = "Found \(hits.count) message\(hits.count == 1 ? "" : "s")"
                + (mailbox.map { " in \($0.title)" } ?? "")
                + (translated.map { " (query: \($0))" } ?? (effectiveQuery.isEmpty ? "" : " (query: \(effectiveQuery))"))
                + "."
            let content = summaryLine + "\n" + searchJSON(hits, nextPageToken: result.nextPageToken)
            return NativeBrowserToolResult(call: call, succeeded: true, content: content)
        } catch {
            return fail(call, "Mail search failed: \(describe(error))")
        }
    }

    // MARK: - Read thread

    private func readThread(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let identifier = call.mailIdentifier else {
            return fail(call, "mail_read_thread requires a message_id or thread_id.")
        }
        do {
            let messages = try await gmail.readThreadForTool(identifier: identifier)
            guard !messages.isEmpty else {
                return fail(call, "No messages found for \(identifier.displayValue).")
            }
            // No silent truncation: a generous default budget, and we say so
            // explicitly if a body is clipped.
            let perMessageBudget = max(call.maxChars ?? 20_000, 2_000)
            let content = threadText(messages, perMessageBudget: perMessageBudget)

            // Best-effort memory extraction from what the user just read.
            if mail.memoryAutoExtractEnabled, let last = messages.last {
                let contact = last.fromAddress
                let full = messages.map { $0.plainBody }.joined(separator: "\n\n")
                let snapshot = String(full.prefix(12_000))
                Task { _ = await mail.autoExtractMemories(fromThread: snapshot, contactEmail: contact) }
            }
            return NativeBrowserToolResult(call: call, succeeded: true, content: content)
        } catch {
            return fail(call, "Reading the thread failed: \(describe(error))")
        }
    }

    // MARK: - Show (the only tool that opens the overlay)

    private func show(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let mailbox = parseMailbox(call.mailbox) ?? .inbox
        openOverlay()
        do {
            let result = try await gmail.searchPaged(
                query: call.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                mailbox: mailbox,
                maxResults: min(max(call.maxResults ?? 30, 1), 50),
                pageToken: nil
            )
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "Opened the \(mailbox.title) view with \(result.summaries.count) message\(result.summaries.count == 1 ? "" : "s")."
            )
        } catch {
            return NativeBrowserToolResult(call: call, succeeded: true, content: "Opened the \(mailbox.title) view.")
        }
    }

    // MARK: - Modify (archive / read / star / label)

    private func modify(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let ids = call.resolvedMessageIDs
        guard !ids.isEmpty else { return fail(call, "mail_modify requires message_ids.") }

        var add: [String] = []
        var remove: [String] = []
        var actions: [String] = []
        if call.archive == true { remove.append("INBOX"); actions.append("archived") }
        if let read = call.markRead {
            if read { remove.append("UNREAD"); actions.append("marked read") }
            else { add.append("UNREAD"); actions.append("marked unread") }
        }
        if let star = call.star {
            if star { add.append("STARRED"); actions.append("starred") }
            else { remove.append("STARRED"); actions.append("unstarred") }
        }
        if let labels = call.addLabels, !labels.isEmpty { add.append(contentsOf: labels); actions.append("labeled") }
        if let labels = call.removeLabels, !labels.isEmpty { remove.append(contentsOf: labels); actions.append("unlabeled") }

        guard !add.isEmpty || !remove.isEmpty else {
            return fail(call, "mail_modify needs at least one action (archive, mark_read, star, add_labels, remove_labels).")
        }

        // Capture thread ids before the change so archiving can clear reminders.
        let affectedThreadIDs = ids.compactMap { id in
            gmail.messages.first(where: { $0.id == id })?.threadId
        }

        do {
            try await gmail.modify(messageIDs: ids, add: add, remove: remove)
            if call.archive == true {
                for threadId in affectedThreadIDs { mail.reminders.dismissThread(threadId) }
            }
            let verb = actions.isEmpty ? "updated" : actions.joined(separator: ", ")
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "\(verb.capitalizedFirst) \(ids.count) message\(ids.count == 1 ? "" : "s")."
            )
        } catch {
            return fail(call, "mail_modify failed: \(describe(error))")
        }
    }

    // MARK: - Draft (voice-matched)

    private func draft(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        // Reply target (thread/message) or a fresh recipient.
        var threadContext = ""
        var threadId: String?
        var inReplyToMessageId: String?
        var recipient = call.to?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var suggestedSubject = call.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        var contactEmail = recipient.isEmpty ? nil : recipient

        if let identifier = call.mailIdentifier {
            do {
                let messages = try await gmail.readThreadForTool(identifier: identifier)
                guard let target = messages.last ?? messages.first else {
                    return fail(call, "That thread has no messages to reply to.")
                }
                threadContext = threadText(messages, perMessageBudget: 6_000)
                threadId = target.threadId
                inReplyToMessageId = target.id
                if recipient.isEmpty { recipient = target.fromAddress }
                contactEmail = target.fromAddress
                if suggestedSubject == nil {
                    suggestedSubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
                }
            } catch {
                return fail(call, "Couldn't load the thread to reply to: \(describe(error))")
            }
        } else if recipient.isEmpty {
            return fail(call, "mail_draft needs a thread/message to reply to, or a `to` recipient.")
        }

        // Voice + memory context.
        let sentBodies = (try? await gmail.recentSentBodies()) ?? []
        await mail.ensureVoiceProfile(sentBodies: sentBodies)
        let memories = mail.memories.relevant(toEmail: contactEmail)

        let content: MailAgent.DraftContent?
        if let body = call.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            // Caller supplied the exact text — respect it verbatim.
            content = MailAgent.DraftContent(subject: suggestedSubject ?? "(no subject)", body: body)
        } else {
            content = await mail.agent.draft(
                threadText: threadContext,
                instructions: call.instructions,
                suggestedSubject: suggestedSubject,
                recipient: recipient,
                voice: mail.voice.profile,
                memories: memories,
                style: call.style
            )
        }

        guard let content else {
            return fail(call, "I couldn't compose a draft for that. Try giving me a clearer instruction.")
        }

        let preview = MailDraftPreview(
            to: recipient,
            cc: call.cc,
            subject: content.subject,
            body: content.body,
            threadId: threadId,
            inReplyToMessageId: inReplyToMessageId,
            sourceMessageId: inReplyToMessageId,
            instructions: call.instructions,
            style: call.style
        )

        let summary = """
        Draft ready for \(recipient.isEmpty ? "your recipient" : recipient).
        Subject: \(content.subject)

        \(content.body)

        (Nothing has been sent. Send mode: \(mail.sendMode.title).)
        """
        return NativeBrowserToolResult(call: call, succeeded: true, content: summary, mailPayload: .draft(preview))
    }

    // MARK: - Send (gated by send mode)

    private func send(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let to = call.to?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = call.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = call.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadId = call.threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inReplyTo = call.messageID?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !to.isEmpty, !body.isEmpty else {
            return fail(call, "mail_send needs at least `to` and `body`.")
        }

        switch mail.sendMode {
        case .draftOnly:
            gmail.stageDraft(to: to, cc: call.cc, subject: subject, body: body, replyToMessageId: inReplyTo, threadId: threadId)
            openOverlay()
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "Per your Draft-only setting, I staged this in the Gmail composer for \(to). Review and hit send when you're ready — nothing was sent."
            )
        case .askFirst:
            // `apply` is set when the user confirms via the draft card's Send
            // button — that click IS the go-ahead, so perform the real send.
            if call.apply == true {
                do {
                    _ = try await gmail.sendMessage(to: to, cc: call.cc, subject: subject, body: body, threadId: threadId, inReplyToMessageId: inReplyTo)
                    if let threadId { mail.reminders.dismissThread(threadId) }
                    return NativeBrowserToolResult(call: call, succeeded: true, content: "Sent to \(to).")
                } catch {
                    return fail(call, "Send failed: \(describe(error))")
                }
            }
            let preview = MailDraftPreview(
                to: to, cc: call.cc, subject: subject, body: body,
                threadId: threadId, inReplyToMessageId: inReplyTo
            )
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "Ready to send to \(to) (subject: \(subject.isEmpty ? "(none)" : subject)). Confirm to send — I won't send without your go-ahead.",
                mailPayload: .draft(preview)
            )
        case .autoSend:
            do {
                _ = try await gmail.sendMessage(to: to, cc: call.cc, subject: subject, body: body, threadId: threadId, inReplyToMessageId: inReplyTo)
                if let threadId { mail.reminders.dismissThread(threadId) }
                return NativeBrowserToolResult(call: call, succeeded: true, content: "Sent to \(to).")
            } catch {
                return fail(call, "Send failed: \(describe(error))")
            }
        }
    }

    // MARK: - Triage

    private func triage(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let scope = (call.scope ?? "inbox").lowercased()
        // Make sure we have inbox messages to classify.
        if scope != "message_ids", gmail.messages.isEmpty || scope == "inbox" || scope == "new" {
            _ = try? await gmail.searchPaged(query: "", mailbox: .inbox, maxResults: 40, pageToken: nil)
        }
        let summaries: [GmailMessageSummary]
        if scope == "message_ids", let ids = call.messageIDs {
            let idSet = Set(ids)
            summaries = gmail.messages.filter { idSet.contains($0.id) }
        } else {
            summaries = gmail.messages
        }
        guard !summaries.isEmpty else {
            return NativeBrowserToolResult(call: call, succeeded: true, content: "No messages to triage.")
        }
        let force = scope != "new"
        let decisions = await mail.classifyIfNeeded(summaries, force: force)
        let counts = Dictionary(grouping: decisions, by: { $0.labelId }).mapValues(\.count)
        let summary = counts.isEmpty
            ? "Triage ran; no new labels were needed."
            : "Triaged \(decisions.count) message\(decisions.count == 1 ? "" : "s"): "
                + counts.map { "\(labelName($0.key)) \($0.value)" }.sorted().joined(separator: ", ") + "."
        return NativeBrowserToolResult(call: call, succeeded: true, content: summary)
    }

    // MARK: - Remind

    private func remind(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let identifier = call.mailIdentifier else {
            return fail(call, "mail_remind needs a message_id or thread_id.")
        }
        guard let whenPhrase = call.when?.trimmingCharacters(in: .whitespacesAndNewlines), !whenPhrase.isEmpty else {
            return fail(call, "mail_remind needs `when` (e.g. \"tomorrow\", \"in 2 days\", \"friday\").")
        }
        var dueAt = NaturalDateParser.resolve(whenPhrase)
        if dueAt == nil {
            dueAt = await mail.agent.resolveReminderDate(whenPhrase, today: Self.todayString())
        }
        guard let dueAt else {
            return fail(call, "I couldn't understand the timing \"\(whenPhrase)\". Try \"tomorrow\", \"in 3 days\", or a weekday.")
        }

        // Pull subject/sender for the reminder from what we know.
        var subject = call.subject ?? ""
        var from = ""
        var threadId = call.threadID ?? ""
        var messageId = call.messageID ?? ""
        if let summary = gmail.messages.first(where: { $0.id == identifier.value || $0.threadId == identifier.value }) {
            if subject.isEmpty { subject = summary.subject }
            from = summary.fromName.isEmpty ? summary.fromAddress : summary.fromName
            if threadId.isEmpty { threadId = summary.threadId }
            if messageId.isEmpty { messageId = summary.id }
        }
        if threadId.isEmpty { threadId = identifier.kind == .thread ? identifier.value : messageId }
        if messageId.isEmpty { messageId = identifier.value }

        let reminder = mail.reminders.add(MailReminder(
            threadId: threadId,
            messageId: messageId,
            subject: subject.isEmpty ? "(no subject)" : subject,
            from: from,
            dueAt: dueAt,
            note: call.note,
            kind: .manual
        ))
        return NativeBrowserToolResult(
            call: call,
            succeeded: true,
            content: "Reminder set for \(Self.format(reminder.dueAt))\(subject.isEmpty ? "" : " — \(subject)")."
        )
    }

    // MARK: - Memory

    private func memory(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let action = (call.action ?? "list").lowercased()
        switch action {
        case "add":
            guard let text = (call.body ?? call.instructions)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return fail(call, "mail_memory add needs `text`.")
            }
            mail.memories.add(text: text, anchor: parseAnchor(call.anchor))
            return NativeBrowserToolResult(call: call, succeeded: true, content: "Got it — I'll remember that.")
        case "search":
            let q = call.query ?? ""
            let results = mail.memories.search(q)
            return NativeBrowserToolResult(call: call, succeeded: true, content: memoryList(results, header: results.isEmpty ? "No matching memories." : "Memories:"))
        case "delete":
            let q = call.query ?? ""
            let matches = mail.memories.search(q)
            for m in matches { mail.memories.delete(id: m.id) }
            return NativeBrowserToolResult(call: call, succeeded: true, content: "Deleted \(matches.count) memor\(matches.count == 1 ? "y" : "ies").")
        default: // list
            let results = mail.memories.memories
            return NativeBrowserToolResult(call: call, succeeded: true, content: memoryList(results, header: results.isEmpty ? "No memories yet." : "Memories:"))
        }
    }

    // MARK: - Formatting

    private func hit(from summary: GmailMessageSummary) -> MailSearchHit {
        let labelName = mail.triage.label(forMessage: summary.id)?.name
        return MailSearchHit(
            id: summary.id,
            threadId: summary.threadId,
            from: summary.fromName.isEmpty ? summary.fromAddress : summary.fromName,
            fromAddress: summary.fromAddress,
            subject: summary.subject,
            date: summary.date,
            snippet: summary.snippet,
            unread: summary.unread,
            starred: summary.starred,
            aiLabels: labelName.map { [$0] } ?? []
        )
    }

    private func searchJSON(_ hits: [MailSearchHit], nextPageToken: String?) -> String {
        let records: [[String: Any]] = hits.map { h in
            var record: [String: Any] = [
                "id": h.id,
                "threadId": h.threadId,
                "from": h.from,
                "fromAddress": h.fromAddress,
                "subject": h.subject,
                "date": Self.format(h.date),
                "snippet": h.snippet,
                "unread": h.unread,
                "starred": h.starred
            ]
            if !h.aiLabels.isEmpty { record["aiLabels"] = h.aiLabels }
            return record
        }
        var payload: [String: Any] = ["results": records]
        if let nextPageToken { payload["nextPageToken"] = nextPageToken }
        return jsonString(payload)
    }

    private func threadText(_ messages: [GmailMessage], perMessageBudget: Int) -> String {
        var lines: [String] = []
        let subject = messages.last?.subject ?? messages.first?.subject ?? "(no subject)"
        lines.append("Subject: \(subject)")
        lines.append("Thread ID: \(messages.last?.threadId ?? "")")
        lines.append("Messages: \(messages.count)")
        for (index, message) in messages.enumerated() {
            lines.append("")
            lines.append("--- Message \(index + 1) of \(messages.count) ---")
            lines.append("Message ID: \(message.id)")
            lines.append("From: \(message.fromName.isEmpty ? message.fromAddress : message.fromName) <\(message.fromAddress)>")
            if !message.to.isEmpty { lines.append("To: \(message.to)") }
            if let cc = message.cc, !cc.isEmpty { lines.append("Cc: \(cc)") }
            lines.append("Date: \(Self.format(message.date))")
            if !message.attachments.isEmpty {
                let names = message.attachments.map { att in
                    att.displaySize.isEmpty ? att.filename : "\(att.filename) (\(att.displaySize))"
                }
                lines.append("Attachments: \(names.joined(separator: ", "))")
            }
            lines.append("Body:")
            let body = message.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                lines.append("(No plain-text body.)")
            } else if body.count > perMessageBudget {
                lines.append(String(body.prefix(perMessageBudget)))
                lines.append("[Body clipped at \(perMessageBudget) of \(body.count) characters. Pass a larger max_chars to read more.]")
            } else {
                lines.append(body)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func memoryList(_ memories: [MailMemory], header: String) -> String {
        guard !memories.isEmpty else { return header }
        let lines = memories.prefix(50).map { "- [\($0.anchor.displayLabel)] \($0.text)" }
        return header + "\n" + lines.joined(separator: "\n")
    }

    private func labelName(_ id: String) -> String { mail.triage.label(id: id)?.name ?? id }

    // MARK: - Parsing helpers

    private func parseMailbox(_ raw: String?) -> GmailMailbox? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        return GmailMailbox(rawValue: raw)
    }

    private func parseAnchor(_ raw: String?) -> MailMemoryAnchor {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .always }
        if raw.hasPrefix("@") { return .domain(String(raw.dropFirst())) }
        if raw.contains("@") { return .email(raw) }
        if raw.lowercased() == "always" { return .always }
        return .activity(raw)
    }

    private func fail(_ call: NativeBrowserToolCall, _ message: String) -> NativeBrowserToolResult {
        NativeBrowserToolResult(call: call, succeeded: false, content: message)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }
}

private extension String {
    /// Capitalizes only the first character (so "marked read, starred" →
    /// "Marked read, starred").
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
