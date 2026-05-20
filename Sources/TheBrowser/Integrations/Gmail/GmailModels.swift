import Foundation

/// Minimal projection of a Gmail message — enough to render the inbox list
/// and the reader pane. We deliberately don't try to mirror Gmail's full
/// message envelope; the parts we don't show stay on the server.
struct GmailMessageSummary: Identifiable, Hashable {
    let id: String
    let threadId: String
    let snippet: String
    let subject: String
    let fromName: String
    let fromAddress: String
    let date: Date
    let unread: Bool
    let starred: Bool
    let labelIDs: [String]
}

/// A fully fetched message, including the decoded plain-text and (optional)
/// HTML body parts. We keep both so the reader can render HTML when
/// available and fall back to text when it isn't.
struct GmailMessage: Identifiable, Hashable {
    let id: String
    let threadId: String
    let subject: String
    let fromName: String
    let fromAddress: String
    let to: String
    let cc: String?
    let date: Date
    let snippet: String
    let plainBody: String
    let htmlBody: String?
    let labelIDs: [String]
    var unread: Bool

    var hasHTML: Bool { htmlBody?.isEmpty == false }
}

/// What the user is doing inside the Gmail view. Drives the right-pane
/// content: inbox list, a single message reader, or a compose form.
enum GmailPaneMode: Equatable {
    case list
    case reading(messageID: String)
    case composing(Draft)

    struct Draft: Equatable {
        var to: String = ""
        var subject: String = ""
        var body: String = ""
        /// When set, the composer was opened as a reply to this message and
        /// the API send will include `In-Reply-To`/`References` headers.
        var inReplyTo: GmailMessage? = nil
    }
}

/// Sidebar entry. Maps to a Gmail system label so the API queries can stay
/// `q=`-free (faster, paginates predictably).
enum GmailMailbox: String, CaseIterable, Identifiable, Hashable {
    case inbox
    case starred
    case sent
    case drafts
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .all: "All Mail"
        }
    }

    var symbolName: String {
        switch self {
        case .inbox: "tray.fill"
        case .starred: "star.fill"
        case .sent: "paperplane.fill"
        case .drafts: "doc.text"
        case .all: "envelope.open"
        }
    }

    /// Gmail label ID that selects this mailbox. `nil` here means the
    /// query uses `q=` instead of `labelIds`.
    var labelID: String? {
        switch self {
        case .inbox: "INBOX"
        case .starred: "STARRED"
        case .sent: "SENT"
        case .drafts: "DRAFT"
        case .all: nil
        }
    }
}

/// Human-readable bucket for the date a message landed in. Used by the
/// inbox list to draw subtle section headers.
enum GmailDateBucket: String, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .earlier: "Earlier"
        }
    }

    static func bucket(for date: Date, now: Date = Date()) -> GmailDateBucket {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)),
           date >= weekStart {
            return .thisWeek
        }
        return .earlier
    }
}
