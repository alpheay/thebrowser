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
            "MAIL CONTEXT — the user is in their email inbox right now. Act like a chief of staff who can see what they see."
        ]

        let query = gmail.query.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Current view: \(gmail.selectedMailbox.title)\(query.isEmpty ? "" : " · search: \"\(query)\"")")

        if let message = gmail.openMessage {
            let who = message.fromName.isEmpty ? message.fromAddress : "\(message.fromName) <\(message.fromAddress)>"
            let labels = mail.labelNames(forMessageID: message.id)
            lines.append("Open thread: \"\(message.subject)\" — from \(who)")
            lines.append("Use these ids to act on it — thread_id: \(message.threadId) · latest message_id: \(message.id)\(labels.isEmpty ? "" : " · AI labels: \(labels.joined(separator: ", "))")")
            let excerpt = MailText.stripQuotedReply(message.plainBody)
            let trimmed = (excerpt.isEmpty ? message.snippet : excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("Latest message:\n\(String(trimmed.prefix(900)))")
            }
            lines.append("When the user says \"this email/thread\", \"reply to this\", \"summarize this\", \"what do they want\", \"archive it\", \"remind me about this\" etc., they mean THIS open thread. Act on it directly with the mail_* tools and the ids above — don't search first.")
        } else {
            let count = gmail.messages.count
            lines.append("\(count) message\(count == 1 ? "" : "s") are loaded in this view; no single thread is open yet. Use mail_search / mail_show / mail_triage / mail_modify to find and act on mail.")
        }

        return lines.joined(separator: "\n")
    }
}
