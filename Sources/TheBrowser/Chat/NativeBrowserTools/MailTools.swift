import Foundation

/// Dispatches every `mail_*` AI tool against the live Gmail account and the
/// intelligent-inbox `MailModel`. This replaces the old three naive tools.
///
/// Design rules (fixing the old tools' flaws):
///   - Reads are SILENT — searching/reading never yanks the visible inbox
///     around. Only `mail_show` puts something on screen.
///   - Results are STRUCTURED — a one-line human summary plus a JSON block the
///     model can parse deterministically, not free prose.
///   - There is ONE send path (`MailModel.send`) and one permission gate, so a
///     tool call can't bypass the user's send-mode or Read Mode.
@MainActor
struct MailToolService {
    let gmail: GmailStore
    let mail: MailModel
    /// Surfaces the Gmail inbox UI (used only by `mail_show`).
    let openInbox: @MainActor () -> Void

    func handle(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard gmail.isSignedInForTools else {
            return result(call, false, "Not signed in to Gmail. Open the inbox (⇧⌘E) and sign in first.")
        }
        switch call.name {
        case .mailSearch:     return await search(call)
        case .mailReadThread: return await readThread(call)
        case .mailShow:       return await show(call)
        case .mailDraft:      return await makeDraft(call)
        case .mailSend:       return await send(call)
        case .mailModify:     return await modify(call)
        case .mailTriage:     return await triage(call)
        case .mailMemory:     return await memory(call)
        case .mailRemind:     return await remind(call)
        default:              return result(call, false, "Unsupported mail tool.")
        }
    }

    // MARK: - Search

    private func search(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let args = MailArgs(call.rawArguments)
        let rawQuery = args.string("query", "q") ?? call.query ?? ""
        let mailbox = parseMailbox(args.string("mailbox", "label") ?? call.mailbox)
        let maxResults = args.int("max_results", "maxResults", "limit") ?? call.maxResults ?? 12
        let naturalLanguage = args.bool("natural_language", "nl") ?? false
        let pageToken = args.string("page_token", "pageToken")

        var effectiveQuery = rawQuery
        if naturalLanguage, !rawQuery.isEmpty,
           let translated = await mail.agent.translateQuery(rawQuery, today: Date()) {
            effectiveQuery = translated
        }

        do {
            let list = try await gmail.toolSearch(query: effectiveQuery, mailbox: mailbox, maxResults: maxResults, pageToken: pageToken)
            var hits = list.summaries.map { MailSearchHit(summary: $0, aiLabels: mail.labelNames(forMessageID: $0.id)) }
            if naturalLanguage, hits.count > 2 {
                let ordered = await mail.agent.rerank(rawQuery, hits: hits)
                let byID = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                hits = ordered.compactMap { byID[$0] }
            }
            let header = "Found \(hits.count) message\(hits.count == 1 ? "" : "s")\(mailbox.map { " in \($0.title)" } ?? "")\(effectiveQuery.isEmpty ? "" : " for \"\(effectiveQuery)\"").\(naturalLanguage && effectiveQuery != rawQuery ? " (query: \(effectiveQuery))" : "")"
            return result(call, true, header + "\n" + MailFormat.searchJSON(hits, nextPageToken: list.nextPageToken))
        } catch {
            return result(call, false, "Mail search failed: \(message(error))")
        }
    }

    // MARK: - Read thread

    private func readThread(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let identifier = call.mailIdentifier else {
            return result(call, false, "mail_read_thread needs a message_id or thread_id.")
        }
        let args = MailArgs(call.rawArguments)
        let wantsSummary = args.bool("summarize", "summary") ?? false
        do {
            let thread = try await gmail.toolFetchThread(identifier: identifier)
            guard !thread.isEmpty else { return result(call, false, "That thread has no messages.") }

            var output = MailFormat.thread(thread, identifier: identifier)
            if wantsSummary {
                let text = MailFormat.threadPlainText(thread)
                if let summary = await mail.agent.summarizeThread(text) {
                    output = "Summary: \(summary)\n\n" + output
                }
            }

            // Best-effort, consent-gated memory extraction (never blocks/sends).
            if mail.memoryAutoExtract {
                let text = MailFormat.threadPlainText(thread)
                let contact = thread.last(where: { $0.fromAddress.lowercased() != (gmail.accountEmail?.lowercased() ?? "") })?.fromAddress
                Task { await mail.proposeMemories(fromThread: text, contactEmail: contact) }
            }
            return result(call, true, output)
        } catch {
            return result(call, false, "Couldn't read that thread: \(message(error))")
        }
    }

    // MARK: - Show (the only UI-opening tool)

    private func show(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let args = MailArgs(call.rawArguments)
        // Always surface the inbox UI first. It owns message loading, progress,
        // error display, and re-authentication — so "show me my mail" works even
        // when a silent prefetch can't get a token.
        openInbox()

        if let identifier = call.mailIdentifier {
            do {
                let thread = try await gmail.toolFetchThread(identifier: identifier)
                gmail.presentThread(thread)
                return result(call, true, "Opened: \(thread.last?.subject ?? "(no subject)")")
            } catch {
                return result(call, true, "Opened the inbox. Couldn't preload that thread (\(message(error))) — the inbox view shows its current state.")
            }
        }

        let mailbox = parseMailbox(args.string("mailbox", "label") ?? call.mailbox) ?? .inbox
        let query = args.string("query", "q") ?? call.query ?? ""
        // Drive the store's own load path so the inbox shows a spinner and any
        // auth/refresh error inline, rather than failing here.
        gmail.selectMailbox(mailbox)
        if query.isEmpty {
            gmail.refreshList(force: true)
        } else {
            gmail.setQuery(query)
        }
        return result(call, true, "Opened \(mailbox.title)\(query.isEmpty ? "" : " filtered by \"\(query)\"").")
    }

    // MARK: - Draft

    private func makeDraft(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let args = MailArgs(call.rawArguments)
        let instructions = args.string("instructions", "instruction", "prompt", "goal")
        let verbatim = args.string("body") ?? call.body
        let style = args.string("style", "tone")

        do {
            if let identifier = call.mailIdentifier {
                // Reply draft.
                let thread = try await gmail.toolFetchThread(identifier: identifier)
                guard let target = thread.last ?? thread.first else {
                    return result(call, false, "That thread has no messages to reply to.")
                }
                await mail.ensureVoiceProfile(gmail: gmail)
                let recipient = target.fromAddress
                let memories = mail.relevantMemories(forRecipient: recipient)
                let threadText = MailFormat.threadPlainText(thread)
                let subject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"

                let content: DraftContent
                if let verbatim, !verbatim.isEmpty {
                    content = DraftContent(subject: nil, body: verbatim)
                } else if let generated = await mail.agent.draft(
                    threadText: threadText, instructions: instructions, suggestedSubject: subject,
                    recipient: recipient, voice: mail.voice, memories: memories, style: style
                ) {
                    content = generated
                } else {
                    return result(call, false, "Couldn't draft a reply (the fast model didn't return usable text). Try again or write the body yourself.")
                }

                let preview = MailDraftPreview(
                    to: recipient,
                    subject: (content.subject?.isEmpty == false) ? content.subject! : subject,
                    body: content.body,
                    threadId: target.threadId,
                    inReplyToMessageID: target.id,
                    sourceMessageID: target.id,
                    instructions: instructions,
                    style: style
                )
                mail.stageDraft(preview)
                return result(call, true, MailFormat.draftStaged(preview, sendMode: mail.sendMode, readMode: mail.readMode))
            } else {
                // New message.
                guard let to = args.string("to") else {
                    return result(call, false, "mail_draft needs a message_id/thread_id to reply to, or a `to` address for a new message.")
                }
                await mail.ensureVoiceProfile(gmail: gmail)
                let memories = mail.relevantMemories(forRecipient: to)
                let subject = args.string("subject") ?? ""
                let content: DraftContent
                if let verbatim, !verbatim.isEmpty {
                    content = DraftContent(subject: subject, body: verbatim)
                } else if let generated = await mail.agent.draft(
                    threadText: "(new message)", instructions: instructions, suggestedSubject: subject,
                    recipient: to, voice: mail.voice, memories: memories, style: style
                ) {
                    content = generated
                } else {
                    return result(call, false, "Couldn't draft that message.")
                }
                let preview = MailDraftPreview(
                    to: to,
                    subject: (content.subject?.isEmpty == false) ? content.subject! : subject,
                    body: content.body,
                    instructions: instructions,
                    style: style
                )
                mail.stageDraft(preview)
                return result(call, true, MailFormat.draftStaged(preview, sendMode: mail.sendMode, readMode: mail.readMode))
            }
        } catch {
            return result(call, false, "Drafting failed: \(message(error))")
        }
    }

    // MARK: - Send (single gate)

    private func send(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let args = MailArgs(call.rawArguments)
        let draft: MailDraftPreview
        if let raw = args.string("draft_id", "draftId"), let uuid = UUID(uuidString: raw), let staged = mail.draft(id: uuid) {
            draft = staged
        } else if let to = args.string("to"), let body = args.string("body") ?? call.body {
            draft = MailDraftPreview(
                to: to,
                subject: args.string("subject") ?? "",
                body: body,
                threadId: args.string("thread_id", "threadId") ?? call.threadID,
                inReplyToMessageID: args.string("in_reply_to", "message_id", "messageId") ?? call.messageID
            )
        } else {
            return result(call, false, "mail_send needs a draft_id from mail_draft, or explicit to + body.")
        }

        let outcome = await mail.send(draft, gmail: gmail, userInitiated: false)
        switch outcome {
        case .sent(let id):
            return result(call, true, "Sent. Gmail message id \(id).")
        case .stagedForReview(let id):
            return result(call, true, "Draft is staged for review (id \(id.uuidString)). Send mode is \"\(mail.sendMode.title)\"\(mail.readMode ? " and Read Mode is on" : "") — the user presses Send on the draft card. Don't claim it was sent.")
        case .heldForRisk(let id, let reason):
            return result(call, true, "Held for review (id \(id.uuidString)): \(reason) The user must approve it on the draft card.")
        case .failed(let msg):
            return result(call, false, "Send failed: \(msg)")
        }
    }

    // MARK: - Modify (batch organize)

    private func modify(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard !mail.readMode else { return result(call, false, "Read Mode is on — organizing (archive/label/star) is paused. Turn it off in Settings → Mail.") }
        let args = MailArgs(call.rawArguments)
        let ids = args.strings("message_ids", "ids", "messageIds") ?? call.messageID.map { [$0] } ?? []
        guard !ids.isEmpty else { return result(call, false, "mail_modify needs message_ids.") }

        var add: [String] = []
        var remove: [String] = []
        var actions: [String] = []
        if args.bool("archive") == true { remove.append("INBOX"); actions.append("archived") }
        switch args.bool("read", "mark_read") {
        case .some(true): remove.append("UNREAD"); actions.append("marked read")
        case .some(false): add.append("UNREAD"); actions.append("marked unread")
        case .none: break
        }
        switch args.bool("star", "starred") {
        case .some(true): add.append("STARRED"); actions.append("starred")
        case .some(false): remove.append("STARRED"); actions.append("unstarred")
        case .none: break
        }
        if let raw = args.strings("add_labels", "addLabelIds") { add.append(contentsOf: raw); actions.append("labeled") }
        if let raw = args.strings("remove_labels", "removeLabelIds") { remove.append(contentsOf: raw) }

        guard !(add.isEmpty && remove.isEmpty) else {
            return result(call, false, "mail_modify needs at least one action: archive, read, star, add_labels, or remove_labels.")
        }
        do {
            try await gmail.toolBatchModify(messageIDs: ids, add: add, remove: remove)
            return result(call, true, "Done — \(actions.isEmpty ? "updated" : actions.joined(separator: ", ")) \(ids.count) message\(ids.count == 1 ? "" : "s").")
        } catch {
            return result(call, false, "Modify failed: \(message(error))")
        }
    }

    // MARK: - Triage

    private func triage(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard !mail.readMode else { return result(call, false, "Read Mode is on — triage labeling is paused.") }
        guard mail.triageEnabled else { return result(call, false, "Triage is disabled in Settings → Mail.") }
        let args = MailArgs(call.rawArguments)
        let scope = (args.string("scope") ?? "inbox").lowercased()
        do {
            let list = try await gmail.toolSearch(query: nil, mailbox: .inbox, maxResults: 30)
            let applied = await mail.triage(list.summaries, gmail: gmail, force: scope == "all")
            let breakdown = MailFormat.triageBreakdown(list.summaries, decisions: { mail.labelNames(forMessageID: $0).first })
            return result(call, true, "Triaged \(list.summaries.count) message\(list.summaries.count == 1 ? "" : "s") (\(applied) newly labeled).\n\(breakdown)")
        } catch {
            return result(call, false, "Triage failed: \(message(error))")
        }
    }

    // MARK: - Memory

    private func memory(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let args = MailArgs(call.rawArguments)
        let action = (args.string("action") ?? "add").lowercased()
        switch action {
        case "add", "create", "remember":
            guard let text = args.string("text", "memory", "content") else {
                return result(call, false, "mail_memory add needs `text`.")
            }
            let anchor = MailMemoryAnchor.parse(args.string("anchor") ?? "always")
            let kind = MailMemoryKind(rawValue: args.string("kind") ?? "") ?? .aboutEntity
            mail.addMemory(MailMemory(text: text, kind: kind, anchor: anchor))
            return result(call, true, "Saved memory (\(kind.label), \(anchor.label)): \(text)")
        case "list":
            return result(call, true, MailFormat.memories(mail.memories))
        case "search":
            let hits = mail.searchMemories(args.string("query", "text") ?? "")
            return result(call, true, MailFormat.memories(hits))
        case "delete", "remove", "forget":
            if let raw = args.string("id"), let uuid = UUID(uuidString: raw) {
                mail.deleteMemory(id: uuid)
                return result(call, true, "Deleted that memory.")
            }
            return result(call, false, "mail_memory delete needs an `id` (from list).")
        default:
            return result(call, false, "Unknown mail_memory action '\(action)'. Use add, list, search, or delete.")
        }
    }

    // MARK: - Remind

    private func remind(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let identifier = call.mailIdentifier else {
            return result(call, false, "mail_remind needs a message_id or thread_id.")
        }
        let args = MailArgs(call.rawArguments)
        let phrase = args.string("when", "time", "date") ?? "tomorrow"
        let note = args.string("note")
        do {
            let thread = try await gmail.toolFetchThread(identifier: identifier)
            guard let target = thread.last ?? thread.first else {
                return result(call, false, "That thread has no messages.")
            }
            let now = Date()
            let resolved = NaturalDateParser.date(from: phrase, now: now)
            let fireAt = resolved ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)).flatMap {
                Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
            } ?? now.addingTimeInterval(86_400)
            mail.addReminder(MailReminder(threadId: target.threadId, subject: target.subject, fireAt: fireAt, note: note, kind: .manual))
            let interpreted = resolved == nil ? " (couldn't parse \"\(phrase)\" precisely — set to tomorrow 9 AM; tell me a clearer time to adjust)" : ""
            return result(call, true, "Reminder set for \(MailFormat.date(fireAt)) on \"\(target.subject)\"\(interpreted).")
        } catch {
            return result(call, false, "Couldn't set the reminder: \(message(error))")
        }
    }

    // MARK: - Helpers

    private func parseMailbox(_ raw: String?) -> GmailMailbox? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        return GmailMailbox(rawValue: raw)
    }

    private func message(_ error: Error) -> String {
        // handle() already verified the account is signed in, so a notSignedIn
        // thrown deeper means the access token couldn't be refreshed (expired /
        // revoked refresh token) — guide the user to reconnect rather than
        // implying they were never signed in.
        if let authError = error as? GmailAuthError, case .notSignedIn = authError, gmail.isSignedInForTools {
            return "Your Gmail session expired. Open the inbox (⇧⌘E), sign out, and sign in again to reconnect."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func result(_ call: NativeBrowserToolCall, _ ok: Bool, _ content: String) -> NativeBrowserToolResult {
        NativeBrowserToolResult(call: call, succeeded: ok, content: content)
    }
}

// MARK: - Argument parsing for the rich mail tools

/// Lenient reader over a mail tool call's raw JSON arguments. Mail tools carry
/// more parameters than the shared `NativeBrowserToolCall` models as typed
/// fields, so they're parsed here on demand. Falls back gracefully when a key
/// is absent or the wrong type.
private struct MailArgs {
    private let dict: [String: Any]

    init(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            dict = [:]
            return
        }
        if let nested = object["arguments"] as? [String: Any] {
            dict = object.merging(nested) { _, new in new }
        } else {
            dict = object
        }
    }

    func string(_ keys: String...) -> String? {
        for key in keys {
            if let s = dict[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let b = dict[key] as? Bool { return b }
            if let n = dict[key] as? NSNumber { return n.boolValue }
            if let s = (dict[key] as? String)?.lowercased() {
                if ["true", "yes", "1"].contains(s) { return true }
                if ["false", "no", "0"].contains(s) { return false }
            }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let i = dict[key] as? Int { return i }
            if let n = dict[key] as? NSNumber { return n.intValue }
            if let s = dict[key] as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        }
        return nil
    }

    func strings(_ keys: String...) -> [String]? {
        for key in keys {
            if let arr = dict[key] as? [Any] {
                let values = arr.compactMap { ($0 as? String) ?? ($0 as? NSNumber).map { "\($0)" } }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !values.isEmpty { return values }
            }
            if let s = dict[key] as? String {
                let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !parts.isEmpty { return parts }
            }
        }
        return nil
    }
}

// MARK: - Output formatting (structured JSON + human summary)

private enum MailFormat {
    static func searchJSON(_ hits: [MailSearchHit], nextPageToken: String?) -> String {
        let items = hits.map { hit -> [String: Any] in
            [
                "id": hit.id,
                "threadId": hit.threadId,
                "from": hit.fromName.isEmpty ? hit.fromAddress : "\(hit.fromName) <\(hit.fromAddress)>",
                "subject": hit.subject,
                "date": date(hit.date),
                "unread": hit.unread,
                "labels": hit.aiLabels,
                "snippet": String(hit.snippet.prefix(160))
            ]
        }
        var payload: [String: Any] = ["results": items]
        if let nextPageToken { payload["nextPageToken"] = nextPageToken }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"results\":[]}"
        }
        return json
    }

    static func thread(_ messages: [GmailMessage], identifier: MailToolMessageIdentifier) -> String {
        var lines: [String] = []
        let subject = messages.last?.subject ?? "(no subject)"
        lines.append("Thread: \(subject)")
        lines.append("Thread ID: \(messages.last?.threadId ?? identifier.value)")
        lines.append("Messages: \(messages.count)")
        for (index, message) in messages.enumerated() {
            lines.append("")
            lines.append("--- Message \(index + 1) of \(messages.count) ---")
            lines.append("Message ID: \(message.id)")
            lines.append("From: \(message.fromName.isEmpty ? message.fromAddress : message.fromName) <\(message.fromAddress)>")
            if !message.to.isEmpty { lines.append("To: \(message.to)") }
            lines.append("Date: \(date(message.date))")
            let body = message.plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let (clipped, didClip) = MailText.clip(body.isEmpty ? "(no plain-text body)" : body, max: 4_000)
            lines.append("Body:")
            lines.append(clipped)
            if didClip { lines.append("[Body clipped to 4,000 characters.]") }
        }
        return lines.joined(separator: "\n")
    }

    static func threadPlainText(_ messages: [GmailMessage]) -> String {
        messages.map { message in
            let who = message.fromName.isEmpty ? message.fromAddress : message.fromName
            let body = MailText.stripQuotedReply(message.plainBody)
            return "\(who) (\(date(message.date))):\n\(body.isEmpty ? message.plainBody : body)"
        }.joined(separator: "\n\n")
    }

    static func draftStaged(_ draft: MailDraftPreview, sendMode: MailSendMode, readMode: Bool) -> String {
        """
        Draft staged for the user to review (id \(draft.id.uuidString)). A draft card is shown with Edit / Regenerate / Rate / Send.
        To: \(draft.to)
        Subject: \(draft.subject)
        Body:
        \(draft.body)

        Send mode is "\(sendMode.title)"\(readMode ? "; Read Mode is on" : ""). Do not claim it was sent — the user (or mail_send, per send mode) controls sending.
        """
    }

    static func triageBreakdown(_ summaries: [GmailMessageSummary], decisions: (String) -> String?) -> String {
        var counts: [String: Int] = [:]
        for summary in summaries {
            let label = decisions(summary.id) ?? "(unlabeled)"
            counts[label, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    static func memories(_ memories: [MailMemory]) -> String {
        guard !memories.isEmpty else { return "No memories stored." }
        return memories.map { "- [\($0.id.uuidString.prefix(8))] (\($0.kind.label), \($0.anchor.label)) \($0.text)" }.joined(separator: "\n")
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
