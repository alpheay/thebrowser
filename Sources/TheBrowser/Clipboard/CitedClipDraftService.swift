import Foundation

/// Turns a set of cited clips into a drafted piece of writing using the
/// configured AI provider. Each clip becomes a numbered citation the
/// model is required to thread back through the draft, with a `## Sources`
/// list at the end so the attribution survives the copy-paste boundary.
///
/// Stateless wrapper around ``AIProviderClient``; the popover model owns
/// the actual `Task` that runs the request so it can be cancelled.
struct CitedClipDraftService {
    var client: AIProviderClient = AIProviderClient()

    func draft(
        clips: [CitedClip],
        preset: CitedClipDraftPreset,
        customInstruction: String = ""
    ) async throws -> String {
        guard !clips.isEmpty else { return "" }

        let userPrompt = Self.userPrompt(
            clips: clips,
            preset: preset,
            customInstruction: customInstruction
        )

        return try await client.ask(
            prompt: userPrompt,
            systemPromptOverride: Self.systemPrompt
        )
    }

    /// Drafting rules that apply to every preset. The system prompt
    /// override means the user's chat persona doesn't leak into a
    /// drafting call (which would otherwise pull in unrelated tool
    /// instructions and identity framing).
    static let systemPrompt = """
    You are a writing assistant inside a web browser. The user has captured a set of cited clips — text snippets, each with a source title and URL — and wants you to draft a short piece of writing that uses them as evidence.

    Hard rules you must follow on every draft:
    - Stay strictly faithful to the clips. Do not invent facts beyond what the clips explicitly say.
    - Cite every factual statement inline using the matching clip's bracketed index, e.g. [1], [2]. Multiple citations may stack, e.g. [1][3].
    - End the draft with a single "## Sources" markdown heading followed by a numbered list of every clip you cited, in the exact format `[N] Title — URL`. Use the same N you used inline.
    - Output only the draft text in plain markdown. No preamble, no postscript, no "Here is your draft" framing, no apologies. Begin with the first line of the draft itself.
    - Use markdown sparingly: headings only where the requested format calls for them; otherwise plain paragraphs and short lists.
    """

    /// Builds the user message: the requested format + per-preset rubric +
    /// optional free-form instruction + the cited clips, each prefixed
    /// with its 1-based index so the model can cite back as `[N]`.
    static func userPrompt(
        clips: [CitedClip],
        preset: CitedClipDraftPreset,
        customInstruction: String
    ) -> String {
        var lines: [String] = []
        lines.append("Format: \(preset.displayName).")

        let instruction = preset.instruction
        if !instruction.isEmpty {
            lines.append(instruction)
        }

        let custom = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            lines.append("Additional instructions from the user: \(custom)")
        }

        lines.append("")
        lines.append("Cited clips (your only source material — cite each one inline with its bracketed index):")
        for (offset, clip) in clips.enumerated() {
            let n = offset + 1
            lines.append("[\(n)] \(sourceLabel(for: clip))")
            for piece in clip.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(piece)")
            }
            lines.append("")
        }
        lines.append("Write the draft now.")
        return lines.joined(separator: "\n")
    }

    private static func sourceLabel(for clip: CitedClip) -> String {
        let title = clip.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = clip.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (title.isEmpty, url.isEmpty) {
        case (false, false): return "\(title) — \(url)"
        case (false, true): return title
        case (true, false): return url
        case (true, true): return clip.pageDomain.isEmpty ? "Unknown source" : clip.pageDomain
        }
    }
}
