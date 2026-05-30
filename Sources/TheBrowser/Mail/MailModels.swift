import Foundation

// Value types for the intelligent-inbox layer. Everything here is a plain
// Codable/Sendable struct or enum so it can be persisted by `MailStore`,
// handed to the `MailAgent` sub-agent across the actor boundary, and rendered
// by SwiftUI without ceremony. Nothing in this file touches Gmail or the LLM —
// it's the shared vocabulary the rest of the Mail module speaks.

// MARK: - Search

/// A single search hit surfaced to the AI tool layer. A thin projection of
/// ``GmailMessageSummary`` plus any AI triage labels we've attached locally.
struct MailSearchHit: Codable, Sendable, Hashable, Identifiable {
    var id: String          // Gmail message id
    var threadId: String
    var subject: String
    var fromName: String
    var fromAddress: String
    var date: Date
    var snippet: String
    var unread: Bool
    var aiLabels: [String]   // AI label names, if classified

    init(summary: GmailMessageSummary, aiLabels: [String] = []) {
        self.id = summary.id
        self.threadId = summary.threadId
        self.subject = summary.subject
        self.fromName = summary.fromName
        self.fromAddress = summary.fromAddress
        self.date = summary.date
        self.snippet = summary.snippet
        self.unread = summary.unread
        self.aiLabels = aiLabels
    }
}

// MARK: - Drafts

/// A draft the AI produced (or the user is refining), staged for review. Holds
/// just enough to (a) render a preview card, (b) re-generate on demand, and
/// (c) send with correct threading — no live `GmailMessage` reference, so it
/// stays Codable and Sendable.
struct MailDraftPreview: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var to: String
    var subject: String
    var body: String
    var threadId: String?
    var inReplyToMessageID: String?
    var sourceMessageID: String?
    /// The natural-language instruction used to generate this draft, kept so
    /// "Regenerate" can re-run with the same intent.
    var instructions: String?
    /// Optional per-recipient register nudge ("formal", "warm and brief", …).
    var style: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        to: String,
        subject: String,
        body: String,
        threadId: String? = nil,
        inReplyToMessageID: String? = nil,
        sourceMessageID: String? = nil,
        instructions: String? = nil,
        style: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.to = to
        self.subject = subject
        self.body = body
        self.threadId = threadId
        self.inReplyToMessageID = inReplyToMessageID
        self.sourceMessageID = sourceMessageID
        self.instructions = instructions
        self.style = style
        self.createdAt = createdAt
    }

    var isReply: Bool { inReplyToMessageID != nil || threadId != nil }
}

/// What the agent generated for a single draft request: the subject + body the
/// model returned. Subject is optional on replies (we keep the thread subject).
struct DraftContent: Codable, Sendable, Hashable {
    var subject: String?
    var body: String
}

/// Output of "rate this draft against its goal" (Slashy's ⌘P feature).
struct DraftRating: Codable, Sendable, Hashable {
    var inferredGoal: String
    var score: Int            // 0...100
    var issues: [String]
    var suggestions: [String]
}

/// The kinds of one-tap edits the draft toolbar offers.
enum DraftEditAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case improve, shorten, lengthen, fixGrammar, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .improve: return "Improve"
        case .shorten: return "Shorten"
        case .lengthen: return "Lengthen"
        case .fixGrammar: return "Fix grammar"
        case .custom: return "Custom…"
        }
    }
    var symbol: String {
        switch self {
        case .improve: return "wand.and.stars"
        case .shorten: return "arrow.down.right.and.arrow.up.left"
        case .lengthen: return "arrow.up.left.and.arrow.down.right"
        case .fixGrammar: return "checkmark.circle"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - Send mode

/// How aggressively the agent is allowed to send. Sending is the single gated
/// action; everything reversible (label/archive/draft/star) is autonomous.
enum MailSendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case draftOnly
    case askFirst
    case autoSend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draftOnly: return "Draft only"
        case .askFirst: return "Ask first"
        case .autoSend: return "Auto-send safe replies"
        }
    }

    var detail: String {
        switch self {
        case .draftOnly:
            return "The agent always stages a draft. You press Send."
        case .askFirst:
            return "The agent prepares the email and waits for your one-tap confirmation."
        case .autoSend:
            return "Low-risk replies send automatically; sensitive or external mail still asks."
        }
    }
}

// MARK: - Triage / AI labels

/// An AI triage label: a name + a natural-language description the classifier
/// reasons over, optional deterministic filters that bypass the LLM, and the
/// behaviours the label drives.
struct AILabel: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var descriptionText: String
    var colorHex: String
    var enabled: Bool
    var isDefault: Bool
    /// Deterministic fast-path: if the sender matches any of these substrings
    /// the message is labelled without calling the model.
    var fromFilters: [String]
    /// Deterministic fast-path on the subject line.
    var subjectFilters: [String]
    var notify: Bool

    init(
        id: UUID = UUID(),
        name: String,
        descriptionText: String,
        colorHex: String,
        enabled: Bool = true,
        isDefault: Bool = false,
        fromFilters: [String] = [],
        subjectFilters: [String] = [],
        notify: Bool = false
    ) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.colorHex = colorHex
        self.enabled = enabled
        self.isDefault = isDefault
        self.fromFilters = fromFilters
        self.subjectFilters = subjectFilters
        self.notify = notify
    }

    /// Deterministic match against sender + subject. Returns true when a filter
    /// fires, letting the caller skip the LLM for this message.
    func deterministicMatch(fromAddress: String, subject: String) -> Bool {
        let from = fromAddress.lowercased()
        let subj = subject.lowercased()
        if fromFilters.contains(where: { !$0.isEmpty && from.contains($0.lowercased()) }) { return true }
        if subjectFilters.contains(where: { !$0.isEmpty && subj.contains($0.lowercased()) }) { return true }
        return false
    }

    /// The seven Slashy-style defaults. Hiring/Investors ship disabled.
    static let defaults: [AILabel] = [
        AILabel(name: "Important", descriptionText: "Time-sensitive messages from real people that need your attention or a reply: direct asks, decisions, approvals, anything from a known VIP or your team.", colorHex: "F2C14E", isDefault: true, notify: true),
        AILabel(name: "Calendar", descriptionText: "Meeting invites, scheduling back-and-forth, calendar holds, reschedules, and event confirmations.", colorHex: "6FA8DC", isDefault: true, subjectFilters: ["invitation:", "invite:", "reschedul"], notify: true),
        AILabel(name: "Billing", descriptionText: "Receipts, invoices, payment confirmations, subscription renewals, and anything finance/expenses related.", colorHex: "8FCB9B", isDefault: true, subjectFilters: ["receipt", "invoice", "payment", "your order"]),
        AILabel(name: "Newsletter", descriptionText: "Bulk newsletters, marketing blasts, product announcements, and digest emails you didn't write to a person.", colorHex: "9B9B9B", isDefault: true),
        AILabel(name: "Hiring", descriptionText: "Recruiting: candidate outreach, applications, interview scheduling, recruiter messages.", colorHex: "B59CD9", enabled: false, isDefault: true),
        AILabel(name: "Investors", descriptionText: "Messages from or about investors, VCs, fundraising, board members, and cap-table matters.", colorHex: "5FB3A1", enabled: false, isDefault: true),
        AILabel(name: "Other", descriptionText: "Everything that doesn't clearly fit another label.", colorHex: "6B6B6B", isDefault: true)
    ]
}

/// A classification decision for one message.
struct TriageDecision: Codable, Sendable, Hashable {
    var messageID: String
    var label: String        // label name, or "" when below threshold
    var confidence: Double   // 0...1
    var reason: String?
}

/// Input handed to the classifier for one message.
struct TriageInput: Codable, Sendable, Hashable {
    var messageID: String
    var subject: String
    var fromName: String
    var fromAddress: String
    var snippet: String

    init(hit: MailSearchHit) {
        self.messageID = hit.id
        self.subject = hit.subject
        self.fromName = hit.fromName
        self.fromAddress = hit.fromAddress
        self.snippet = hit.snippet
    }

    init(summary: GmailMessageSummary) {
        self.messageID = summary.id
        self.subject = summary.subject
        self.fromName = summary.fromName
        self.fromAddress = summary.fromAddress
        self.snippet = summary.snippet
    }
}

/// A user correction, stored as a few-shot example to sharpen future triage.
struct TriageExample: Codable, Sendable, Hashable {
    var subject: String
    var fromAddress: String
    var snippet: String
    var label: String
}

// MARK: - Memories

/// Where a memory applies. Slashy's anchor model: a specific address, a whole
/// domain, an activity tag, or always.
enum MailMemoryAnchor: Sendable, Hashable {
    case always
    case email(String)
    case domain(String)
    case activity(String)

    /// Canonical string form used for persistence and tool I/O:
    /// "always", "email:foo@bar.com", "domain:bar.com", "activity:scheduling".
    var stringValue: String {
        switch self {
        case .always: return "always"
        case .email(let v): return "email:\(v.lowercased())"
        case .domain(let v): return "domain:\(v.lowercased())"
        case .activity(let v): return "activity:\(v.lowercased())"
        }
    }

    static func parse(_ raw: String) -> MailMemoryAnchor {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "always" || lower.isEmpty { return .always }
        if let range = trimmed.range(of: ":") {
            let kind = String(trimmed[trimmed.startIndex..<range.lowerBound]).lowercased()
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case "email": return .email(value.lowercased())
            case "domain": return .domain(value.lowercased())
            case "activity": return .activity(value.lowercased())
            default: break
            }
        }
        // Bare value that looks like an address/domain → infer.
        if trimmed.contains("@") { return .email(lower) }
        if trimmed.contains(".") { return .domain(lower) }
        return .activity(lower)
    }

    var label: String {
        switch self {
        case .always: return "Always"
        case .email(let v): return v
        case .domain(let v): return v
        case .activity(let v): return "activity: \(v)"
        }
    }
}

extension MailMemoryAnchor: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MailMemoryAnchor.parse(raw)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

enum MailMemoryKind: String, Codable, Sendable, CaseIterable {
    case aboutMe
    case aboutEntity
    case todo
    case snippet

    var label: String {
        switch self {
        case .aboutMe: return "About me"
        case .aboutEntity: return "About contact"
        case .todo: return "Todo"
        case .snippet: return "Snippet"
        }
    }
}

struct MailMemory: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var kind: MailMemoryKind
    var anchor: MailMemoryAnchor
    var createdAt: Date
    var dueDate: Date?

    init(
        id: UUID = UUID(),
        text: String,
        kind: MailMemoryKind = .aboutEntity,
        anchor: MailMemoryAnchor = .always,
        createdAt: Date = Date(),
        dueDate: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.anchor = anchor
        self.createdAt = createdAt
        self.dueDate = dueDate
    }

    /// True when this memory is relevant to a draft addressed to `email`.
    func applies(toEmail email: String?) -> Bool {
        switch anchor {
        case .always:
            return true
        case .email(let addr):
            guard let email = email?.lowercased() else { return false }
            return email == addr.lowercased()
        case .domain(let dom):
            guard let email = email?.lowercased(),
                  let at = email.range(of: "@") else { return false }
            return email[at.upperBound...].hasSuffix(dom.lowercased())
        case .activity:
            return false   // activity memories are pulled in explicitly by tag
        }
    }
}

// MARK: - Reminders (lightweight, app-open)

struct MailReminder: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable {
        case manual
        case droppedBall
    }

    var id: UUID
    var threadId: String
    var subject: String
    var fireAt: Date
    var note: String?
    var kind: Kind
    var dismissed: Bool

    init(
        id: UUID = UUID(),
        threadId: String,
        subject: String,
        fireAt: Date,
        note: String? = nil,
        kind: Kind = .manual,
        dismissed: Bool = false
    ) {
        self.id = id
        self.threadId = threadId
        self.subject = subject
        self.fireAt = fireAt
        self.note = note
        self.kind = kind
        self.dismissed = dismissed
    }
}

// MARK: - Voice

/// A distilled description of how the user writes, learned from Sent mail.
struct VoiceProfile: Codable, Sendable, Hashable {
    var descriptor: String       // e.g. "Warm but concise; first-name greeting; signs off 'Best, Nik'."
    var greeting: String?
    var signature: String?
    var sampleCount: Int
    var updatedAt: Date

    static let empty = VoiceProfile(descriptor: "", greeting: nil, signature: nil, sampleCount: 0, updatedAt: .distantPast)

    var isUsable: Bool { sampleCount > 0 && !descriptor.isEmpty }
}
