import Foundation

/// Builds the ambient "what the user is looking at in their inbox" block that
/// rides along in the chat prompt. This is what makes the chat panel a
/// context-aware partner inside mail: with the open thread's ids + excerpt in
/// hand, the agent resolves "reply to this", "summarize this", "what does she
/// want", "archive it" against the open thread without searching first.
enum MailContext {
    @MainActor
    static func promptBlock(gmail: GmailStore, mail: MailModel) -> String? {
        guard gmail.isSignedInForTools else { return nil }

        var lines: [String] = [
            "INBOX CONTEXT — you are looking at the user's inbox WITH them right now, like a chief of staff seeing their screen. The facts below are what they currently see. Answer questions about the open email or the current view DIRECTLY from this context — do NOT call mail_search or mail_show just to discover what is already open in front of them."
        ]

        let query = gmail.query.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Current view: \(gmail.selectedMailbox.title)\(query.isEmpty ? "" : " · search: \"\(query)\"")")

        if let draft = gmail.currentDraft {
            // The user is actively writing — this is what they're typing.
            lines.append("THE USER IS COMPOSING A DRAFT right now\(draft.inReplyTo != nil ? " (a reply to the thread below)" : "").")
            if !draft.to.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("To: \(draft.to)") }
            if !draft.subject.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Subject: \(draft.subject)") }
            let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("Draft body so far:\n\(body.isEmpty ? "(empty)" : String(body.prefix(1500)))")
            if let source = draft.inReplyTo {
                lines.append("Replying to \(source.fromName.isEmpty ? source.fromAddress : source.fromName) about \"\(source.subject)\".")
            }
            lines.append("To write or revise THIS draft in the composer — \"make it more formal\", \"shorten this\", \"add a line about X\", \"finish it\", \"reword the opening\" — call mail_compose with an `instruction` (or `body` to replace it wholesale). mail_compose edits the email the user is typing IN PLACE; do not make a separate draft card for it.")
        } else if let message = gmail.openMessage {
            let who = message.fromName.isEmpty ? message.fromAddress : "\(message.fromName) <\(message.fromAddress)>"
            let labels = mail.labelNames(forMessageID: message.id)
            lines.append("THE OPEN EMAIL the user is reading:")
            lines.append("Subject: \"\(message.subject)\" · From: \(who) · Date: \(formatted(message.date))")
            lines.append("Ids to act on it — thread_id: \(message.threadId) · message_id: \(message.id)\(labels.isEmpty ? "" : " · AI labels: \(labels.joined(separator: ", "))")")
            let excerpt = MailText.stripQuotedReply(message.plainBody)
            let trimmed = (excerpt.isEmpty ? message.snippet : excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("Body:\n\(String(trimmed.prefix(1100)))")
            }
            lines.append("\"this email/thread\", \"what am I looking at\", \"who is this from\", \"what do they want\", \"summarize this\", \"reply to this\", \"archive it\", \"remind me about this\" ALL refer to THIS email — answer or act on it directly. To draft a reply the user can edit inline, use mail_compose (it opens/fills the native composer). To organize, use mail_modify with the ids above.")
        } else {
            let count = gmail.messages.count
            lines.append("\(count) message\(count == 1 ? "" : "s") are loaded in this view; no single email is open yet. Use mail_search / mail_show / mail_triage / mail_modify to find and act on mail.")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
