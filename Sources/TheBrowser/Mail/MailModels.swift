import Foundation
import SwiftUI

// The data layer for TheBrowser's intelligent inbox. Everything here is
// local-first and Codable so it persists under ~/.thebrowser/mail/ next to
// the existing chat sessions and web artifacts. Nothing in this file talks to
// the network or the AI — it's pure model + storage so the stores, the mail
// sub-agent, and the tool harness can all share one vocabulary.

// MARK: - Attachments

/// Metadata for a file attached to a Gmail message. We surface the name,
/// type, and size so the assistant can say "this has contract.pdf (240 KB)"
/// without downloading the bytes.
struct MailAttachment: Identifiable, Hashable, Codable, Sendable {
    let filename: String
    let mimeType: String
    let size: Int
    let attachmentId: String

    var id: String { attachmentId.isEmpty ? filename : attachmentId }

    /// Human-readable size, e.g. "240 KB". Empty when the server didn't
    /// report a size.
    var displaySize: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Structured search results

/// One row of a `mail_search` result. Mirrors `GmailMessageSummary` but is
/// Codable and carries AI labels, so the tool can emit stable JSON the fast
/// model parses deterministically (instead of the old brittle prose).
struct MailSearchHit: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let threadId: String
    let from: String
    let fromAddress: String
    let subject: String
    let date: Date
    let snippet: String
    let unread: Bool
    let starred: Bool
    var aiLabels: [String]
}

// MARK: - Draft preview

/// A reply (or fresh message) the assistant has composed and is showing the
/// user for review. This is the centerpiece of the inbox experience: it
/// renders as a card with Accept / Edit / Regenerate / Send and never sends
/// on its own — `MailSendMode` decides what Send actually does.
struct MailDraftPreview: Identifiable, Equatable, Hashable, Sendable, Codable {
    var id: UUID = UUID()
    var to: String
    var cc: String?
    var subject: String
    var body: String
    /// Set when this is a reply, so the send threads correctly and Gmail
    /// stitches In-Reply-To / References headers.
    var threadId: String?
    var inReplyToMessageId: String?
    /// The message this draft is answering, for Regenerate context.
    var sourceMessageId: String?
    /// The instruction the user gave ("decline politely", "say yes to Thu"),
    /// kept so Regenerate can re-run with the same intent.
    var instructions: String?
    /// Optional one-word tone nudge ("warm", "brief", "formal").
    var style: String?

    var isReply: Bool { threadId != nil || inReplyToMessageId != nil }
}

// MARK: - Tool UI payloads

/// Optional rich payload attached to a mail tool result. The model still
/// gets `content` (compact JSON + a one-line summary); this drives the
/// SwiftUI cards in the chat panel. Kept deliberately small — most mail
/// surfaces (triage, reminders) render in the Gmail overlay, not the chat.
enum MailToolPayload: Equatable, Sendable {
    case draft(MailDraftPreview)
}

// MARK: - AI triage labels

/// One AI label. Built-in labels ship with sensible defaults; users can add
/// their own. `instruction` is the natural-language rule the classifier
/// follows ("payments, invoices, receipts, billing").
struct AILabel: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var instruction: String
    var enabled: Bool
    var colorHex: String
    var isBuiltIn: Bool

    var color: Color { Color(hex: colorHex) ?? .gray }

    /// The seven Slashy-style defaults. Hiring and Investors ship disabled
    /// so the inbox stays uncluttered until the user opts in.
    static let defaults: [AILabel] = [
        AILabel(id: "important", name: "Important", instruction: "Messages from real people that need your attention or a reply — customers, colleagues, anything time-sensitive.", enabled: true, colorHex: "#E5484D", isBuiltIn: true),
        AILabel(id: "calendar", name: "Calendar", instruction: "Meeting invites, scheduling requests, calendar reminders, anything about when to meet.", enabled: true, colorHex: "#4C6EF5", isBuiltIn: true),
        AILabel(id: "billing", name: "Billing", instruction: "Payments, invoices, receipts, renewals, subscriptions, and anything finance-related.", enabled: true, colorHex: "#2F9E44", isBuiltIn: true),
        AILabel(id: "newsletter", name: "Newsletter", instruction: "Subscriptions, digests, marketing, product updates, and automated bulk mail.", enabled: true, colorHex: "#F08C00", isBuiltIn: true),
        AILabel(id: "hiring", name: "Hiring", instruction: "Recruiter outreach, job applications, candidate and interview communications.", enabled: false, colorHex: "#9C36B5", isBuiltIn: true),
        AILabel(id: "investors", name: "Investors", instruction: "Investor relations, fundraising, updates to or from VCs and angels.", enabled: false, colorHex: "#0CA678", isBuiltIn: true),
        AILabel(id: "other", name: "Other", instruction: "Anything that doesn't fit the other labels.", enabled: true, colorHex: "#868E96", isBuiltIn: true)
    ]
}

/// The classifier's verdict for one message.
struct TriageDecision: Equatable, Hashable, Codable, Sendable {
    let messageId: String
    let labelId: String
    let confidence: Double
}

/// A message handed to the classifier. Compact on purpose — the fast model
/// only needs sender, subject, and a snippet to label well.
struct TriageInput: Equatable, Hashable, Codable, Sendable {
    let messageId: String
    let from: String
    let subject: String
    let snippet: String
}

/// A correction the user made by re-labelling. Fed back into later classify
/// passes as few-shot examples so the same mistake doesn't repeat.
struct TriageExample: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    let from: String
    let subject: String
    let snippet: String
    let correctLabelId: String
}

// MARK: - Memories

/// Where a memory applies. `always` is global; the rest scope a fact to a
/// person, a company domain, or a kind of activity ("scheduling").
struct MailMemoryAnchor: Equatable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case always, email, domain, activity
    }
    var kind: Kind
    var value: String

    static let always = MailMemoryAnchor(kind: .always, value: "")
    static func email(_ v: String) -> MailMemoryAnchor { .init(kind: .email, value: v.lowercased()) }
    static func domain(_ v: String) -> MailMemoryAnchor { .init(kind: .domain, value: v.lowercased()) }
    static func activity(_ v: String) -> MailMemoryAnchor { .init(kind: .activity, value: v.lowercased()) }

    var displayLabel: String {
        switch kind {
        case .always: return "always"
        case .email: return value
        case .domain: return "@\(value)"
        case .activity: return value
        }
    }
}

/// One remembered fact, preference, or instruction. Auto-extracted memories
/// carry `source == "auto"` and stay unconfirmed until the user keeps them.
struct MailMemory: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var text: String
    var anchor: MailMemoryAnchor
    var createdAt: Date
    var source: String
    var confirmed: Bool

    init(
        id: UUID = UUID(),
        text: String,
        anchor: MailMemoryAnchor,
        createdAt: Date = Date(),
        source: String = "manual",
        confirmed: Bool = true
    ) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.createdAt = createdAt
        self.source = source
        self.confirmed = confirmed
    }
}

// MARK: - Reminders

/// A follow-up nudge. `manual` reminders are user-created ("remind me Friday");
/// `droppedBall` ones are inferred by the scanner for threads awaiting a reply.
struct MailReminder: Identifiable, Equatable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case manual, droppedBall }

    var id: UUID = UUID()
    var threadId: String
    var messageId: String
    var subject: String
    var from: String
    var dueAt: Date
    var note: String?
    var kind: Kind
    var createdAt: Date
    /// Set once the nudge has been surfaced, so we don't re-fire every scan.
    var firedAt: Date?

    init(
        id: UUID = UUID(),
        threadId: String,
        messageId: String,
        subject: String,
        from: String,
        dueAt: Date,
        note: String? = nil,
        kind: Kind = .manual,
        createdAt: Date = Date(),
        firedAt: Date? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.messageId = messageId
        self.subject = subject
        self.from = from
        self.dueAt = dueAt
        self.note = note
        self.kind = kind
        self.createdAt = createdAt
        self.firedAt = firedAt
    }

    var isDue: Bool { dueAt <= Date() }
}

// MARK: - Voice profile

/// A compact, on-device description of how the user writes, distilled once
/// from a sample of their Sent mail and cached. Injected into draft prompts
/// so replies sound like them, not like a chatbot.
struct VoiceProfile: Equatable, Hashable, Codable, Sendable {
    var descriptor: String
    var greeting: String?
    var signoff: String?
    var builtAt: Date
    var sampleCount: Int

    var isEmpty: Bool { descriptor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Send mode

/// What the AI is allowed to do when it wants to send mail. Defaults to
/// `.draftOnly` — the safest option, matching the old behavior — and is
/// configurable in Settings → Mail.
enum MailSendMode: String, CaseIterable, Identifiable, Sendable {
    case draftOnly
    case askFirst
    case autoSend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draftOnly: return "Draft only"
        case .askFirst: return "Ask before sending"
        case .autoSend: return "Smart auto-send"
        }
    }

    var detail: String {
        switch self {
        case .draftOnly: return "The assistant stages a draft in the composer; you send it yourself."
        case .askFirst: return "The assistant shows a preview with a Send button; one click sends."
        case .autoSend: return "Low-risk replies send automatically; anything sensitive still asks."
        }
    }
}

// MARK: - Color hex helper

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (and the 8-digit AARRGGBB variant) into a
    /// SwiftUI Color. Returns nil for anything it can't read so callers fall
    /// back to a default.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            a = Double((value & 0xFF000000) >> 24) / 255
            r = Double((value & 0x00FF0000) >> 16) / 255
            g = Double((value & 0x0000FF00) >> 8) / 255
            b = Double(value & 0x000000FF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
