import Foundation

/// Drafting recipes the user can pick when turning a set of cited clips
/// into a longer piece of writing. Each preset carries a friendly label,
/// SF Symbol, one-line description, and a block of writing instructions
/// that get spliced into the prompt sent to the AI provider.
enum CitedClipDraftPreset: String, CaseIterable, Identifiable {
    case note
    case email
    case argument
    case bugReport
    case researchSummary
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .note: "Note"
        case .email: "Email"
        case .argument: "Argument"
        case .bugReport: "Bug report"
        case .researchSummary: "Research summary"
        case .custom: "Custom…"
        }
    }

    var symbolName: String {
        switch self {
        case .note: "note.text"
        case .email: "envelope"
        case .argument: "bubble.left.and.bubble.right"
        case .bugReport: "ant"
        case .researchSummary: "doc.text.magnifyingglass"
        case .custom: "wand.and.stars"
        }
    }

    var subtitle: String {
        switch self {
        case .note: "Pull the clips into a short standalone note."
        case .email: "Draft an email that uses the clips as evidence."
        case .argument: "Make a tight argument with the clips as support."
        case .bugReport: "Write a structured bug report from the clips."
        case .researchSummary: "Summarize key findings across the clips."
        case .custom: "Describe exactly what you want the draft to do."
        }
    }

    /// Per-preset writing instructions appended to the user message. Kept
    /// terse so the model can prioritize the clips themselves over a long
    /// preamble; the global drafting rules live in the system prompt.
    var instruction: String {
        switch self {
        case .note:
            return """
            Write a concise standalone note that synthesizes the clips. Open with a one-sentence thesis, then 2-4 short paragraphs (or a short bulleted list) that weave the clips together. Aim for ~120-200 words.
            """
        case .email:
            return """
            Draft a short, professional email. Open with a single subject line prefixed with "Subject: ", then a greeting, 2-3 short paragraphs, and a sign-off. Use the clips as evidence and cite each one inline with [N].
            """
        case .argument:
            return """
            Make a tight argument. Open with the claim in one sentence, then 2-4 supporting points each backed by a citation, then close with a one-sentence conclusion. Be direct and avoid hedging.
            """
        case .bugReport:
            return """
            Write a structured bug report using these markdown sections in order:
            ## Summary
            ## Steps to reproduce
            ## Expected behaviour
            ## Actual behaviour
            ## Notes
            Sort the detail from the clips into the right section. Prefer bullet lists.
            """
        case .researchSummary:
            return """
            Write a research summary. Lead with a 2-3 sentence TL;DR, then a "## Key findings" heading followed by 3-6 bullet points (each citing the relevant clip(s)), and close with a "## Open questions" heading listing 1-3 things the clips don't yet answer.
            """
        case .custom:
            return ""
        }
    }
}
