import Foundation

/// The inbox's brain. Every reasoning task the mail subsystem needs —
/// classifying messages into labels, writing voice-matched drafts,
/// translating a natural-language search into Gmail operators, re-ranking
/// results, distilling a writing-style profile, extracting memories — runs
/// here as a one-shot call on a FAST model (gpt-5.4-mini / claude-haiku-4-5)
/// via `AIProviderClient.complete`. It never touches the 25-iteration chat
/// loop, so the main chat model and these cheap background calls stay
/// completely separate.
///
/// Replies are asked for as raw JSON; small models occasionally wrap that in
/// prose or fences, so every parse goes through `MailJSON.decode`, which
/// recovers the first balanced JSON value. Each method degrades gracefully —
/// a failed/unparseable call returns nil or the input unchanged so the inbox
/// keeps working.
struct MailAgent: Sendable {
    private let client = AIProviderClient()

    /// The provider the sub-agent runs on. Honors Settings → Mail when set,
    /// otherwise follows the user's main chat provider (so a codex user gets
    /// gpt-5.4-mini and a claude user gets claude-haiku-4-5 with zero config).
    /// Reads `UserDefaults.standard` directly (thread-safe) so the agent stays
    /// a `Sendable` value the inbox coordinator can hand to detached tasks.
    private var provider: AIProviderKind {
        let configured = UserDefaults.standard.string(forKey: PreferenceKey.mailSubagentProvider) ?? ""
        if let explicit = AIProviderKind(rawValue: configured) { return explicit }
        let main = UserDefaults.standard.string(forKey: PreferenceKey.aiProvider) ?? ""
        return AIProviderKind(rawValue: main) ?? .codex
    }

    private static let systemPrompt = """
    You are the email intelligence engine inside TheBrowser, a fast and precise \
    assistant for working with a person's inbox. You classify, draft, search, \
    and summarize email. Follow the task exactly. When asked for JSON, reply \
    with ONLY the raw JSON value — no prose, no markdown fences, no commentary. \
    Never invent facts about the user or their contacts; use only what the task \
    provides.
    """

    // MARK: - Low-level

    private func run(_ prompt: String) async -> String? {
        do {
            let text = try await client.complete(
                prompt: prompt,
                provider: provider,
                systemPrompt: Self.systemPrompt
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            #if DEBUG
            print("MailAgent: completion failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Triage

    private struct ClassifyRow: Decodable {
        let id: String
        let label: String
        let confidence: Double?
    }

    /// Assigns exactly one enabled label to each input message. Unknown or
    /// missing verdicts are dropped — the caller decides what to do with
    /// unlabeled messages (typically leaves them alone).
    func classify(
        _ inputs: [TriageInput],
        labels: [AILabel],
        examples: [TriageExample] = []
    ) async -> [TriageDecision] {
        let enabled = labels.filter { $0.enabled }
        guard !inputs.isEmpty, !enabled.isEmpty else { return [] }

        let labelBlock = enabled
            .map { "- \($0.id): \($0.name) — \($0.instruction)" }
            .joined(separator: "\n")

        var exampleBlock = ""
        if !examples.isEmpty {
            let lines = examples.prefix(12).map {
                "- from \"\($0.from)\", subject \"\($0.subject)\" → \($0.correctLabelId)"
            }
            exampleBlock = "\nPast corrections from the user (respect these):\n" + lines.joined(separator: "\n") + "\n"
        }

        let messageBlock = inputs.enumerated().map { _, m in
            "{\"id\":\"\(m.messageId)\",\"from\":\(jsonString(m.from)),\"subject\":\(jsonString(m.subject)),\"snippet\":\(jsonString(m.snippet))}"
        }.joined(separator: "\n")

        let prompt = """
        Classify each email into exactly ONE of these labels by id:
        \(labelBlock)
        \(exampleBlock)
        Emails to classify (one JSON object per line):
        \(messageBlock)

        Reply with ONLY a JSON array, one object per email, like:
        [{"id":"<message id>","label":"<label id>","confidence":0.0-1.0}]
        Use only the label ids listed above. Include every email exactly once.
        """

        guard let response = await run(prompt),
              let rows = MailJSON.decode([ClassifyRow].self, from: response)
        else { return [] }

        let validIDs = Set(enabled.map(\.id))
        return rows.compactMap { row in
            let label = row.label.lowercased()
            guard validIDs.contains(label) else { return nil }
            return TriageDecision(
                messageId: row.id,
                labelId: label,
                confidence: row.confidence ?? 0.5
            )
        }
    }

    // MARK: - Drafting

    struct DraftContent: Equatable, Sendable {
        var subject: String
        var body: String
    }

    private struct DraftResponse: Decodable {
        let subject: String?
        let body: String
    }

    /// Writes a reply (or fresh message) in the user's voice. `threadText` is
    /// the conversation so far; `instructions` is what the user asked for;
    /// `voice`, `memories`, and `style` shape tone and content. Returns nil if
    /// the model produced nothing usable.
    func draft(
        threadText: String,
        instructions: String?,
        suggestedSubject: String?,
        recipient: String?,
        voice: VoiceProfile?,
        memories: [MailMemory] = [],
        style: String? = nil
    ) async -> DraftContent? {
        var sections: [String] = []

        if let voice, !voice.isEmpty {
            var voiceLines = ["The user's writing style: \(voice.descriptor)"]
            if let g = voice.greeting, !g.isEmpty { voiceLines.append("They usually greet with: \(g)") }
            if let s = voice.signoff, !s.isEmpty { voiceLines.append("They usually sign off with: \(s)") }
            sections.append(voiceLines.joined(separator: "\n"))
        }

        if !memories.isEmpty {
            let lines = memories.prefix(12).map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("Relevant things to remember:\n\(lines)")
        }

        if let recipient, !recipient.isEmpty {
            sections.append("You are writing to: \(recipient)")
        }

        if let style, !style.isEmpty {
            sections.append("Desired tone: \(style)")
        }

        let intent = (instructions?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Write the most useful, appropriate reply to the latest message in this thread."

        sections.append("What to write: \(intent)")
        sections.append("Conversation so far:\n\(threadText)")

        let subjectHint = suggestedSubject.map { "Use the subject \"\($0)\" unless a better one is clearly needed." } ?? ""

        let prompt = """
        Compose an email on the user's behalf. Sound like them — natural, not robotic. \
        Do not include a subject line or signature inside the body unless the user \
        normally signs that way. Keep it focused and ready to send. \(subjectHint)

        \(sections.joined(separator: "\n\n"))

        Reply with ONLY this JSON:
        {"subject":"<subject line>","body":"<the email body>"}
        """

        guard let response = await run(prompt),
              let parsed = MailJSON.decode(DraftResponse.self, from: response)
        else { return nil }

        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let subject = (parsed.subject?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? suggestedSubject
            ?? "(no subject)"
        return DraftContent(subject: subject, body: body)
    }

    // MARK: - Natural-language search

    private struct QueryResponse: Decodable { let query: String }

    /// Turns a plain-English request into a Gmail search-operator string
    /// (`from:`, `subject:`, `newer_than:`, `has:attachment`, …). Returns nil
    /// when the model can't produce one; the caller can fall back to a literal
    /// search.
    func translateQuery(_ natural: String, today: String) async -> String? {
        let prompt = """
        Convert this natural-language email request into a Gmail search query \
        using Gmail search operators (from:, to:, subject:, newer_than:, \
        older_than:, has:attachment, is:unread, label:, "exact phrase", etc). \
        Today is \(today). Keep it tight and high-recall.

        Request: \(natural)

        Reply with ONLY this JSON: {"query":"<gmail query>"}
        """
        guard let response = await run(prompt),
              let parsed = MailJSON.decode(QueryResponse.self, from: response)
        else { return nil }
        let q = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    private struct RerankResponse: Decodable { let ids: [String] }

    /// Re-orders search hits by relevance to the original request, returning
    /// message ids best-first. Returns the input order on failure.
    func rerank(_ natural: String, hits: [MailSearchHit]) async -> [String] {
        guard hits.count > 1 else { return hits.map(\.id) }
        let block = hits.map {
            "{\"id\":\"\($0.id)\",\"from\":\(jsonString($0.from)),\"subject\":\(jsonString($0.subject)),\"snippet\":\(jsonString($0.snippet))}"
        }.joined(separator: "\n")
        let prompt = """
        The user searched for: \(natural)
        Re-rank these emails from most to least relevant to that request.
        Emails (one JSON object per line):
        \(block)

        Reply with ONLY this JSON: {"ids":["<id>", "<id>", ...]} listing every id once, best first.
        """
        guard let response = await run(prompt),
              let parsed = MailJSON.decode(RerankResponse.self, from: response)
        else { return hits.map(\.id) }

        let known = Set(hits.map(\.id))
        var ordered = parsed.ids.filter { known.contains($0) }
        // Append anything the model dropped so we never lose results.
        let seen = Set(ordered)
        ordered.append(contentsOf: hits.map(\.id).filter { !seen.contains($0) })
        return ordered
    }

    // MARK: - Memory extraction

    private struct MemoryRow: Decodable {
        let text: String
        let anchor: String?
        let value: String?
    }

    /// Pulls durable facts/preferences/commitments out of a thread the user
    /// read or sent. Returns unconfirmed `auto` memories the caller can offer
    /// to keep. Returns [] when there's nothing worth remembering.
    func extractMemories(from threadText: String, contactEmail: String?) async -> [MailMemory] {
        let contactLine = contactEmail.map { "The other party is: \($0)" } ?? ""
        let prompt = """
        Read this email thread and extract any durable facts, preferences, \
        commitments, or instructions worth remembering for future emails \
        (e.g. "prefers afternoon meetings", "company address is …", "owes a \
        reply about the contract"). Skip anything ephemeral or trivial. \
        \(contactLine)

        Thread:
        \(threadText)

        Reply with ONLY a JSON array (empty if nothing is worth keeping):
        [{"text":"<fact>","anchor":"email|domain|activity|always","value":"<email, domain, or activity keyword; empty for always>"}]
        At most 3 items.
        """
        guard let response = await run(prompt),
              let rows = MailJSON.decode([MemoryRow].self, from: response)
        else { return [] }

        return rows.prefix(3).compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let anchor = resolveAnchor(kind: row.anchor, value: row.value, fallbackEmail: contactEmail)
            return MailMemory(text: text, anchor: anchor, source: "auto", confirmed: false)
        }
    }

    private func resolveAnchor(kind: String?, value: String?, fallbackEmail: String?) -> MailMemoryAnchor {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (kind ?? "").lowercased() {
        case "email":
            let email = v.isEmpty ? (fallbackEmail ?? "") : v
            return email.isEmpty ? .always : .email(email)
        case "domain":
            let domain = v.isEmpty ? (fallbackEmail.flatMap { $0.split(separator: "@").last.map(String.init) } ?? "") : v
            return domain.isEmpty ? .always : .domain(domain)
        case "activity":
            return v.isEmpty ? .always : .activity(v)
        default:
            return .always
        }
    }

    // MARK: - Voice profile

    private struct VoiceResponse: Decodable {
        let descriptor: String
        let greeting: String?
        let signoff: String?
    }

    /// Distills a compact writing-style descriptor from a sample of the user's
    /// sent messages. Called once and cached; returns nil on failure so the
    /// caller can retry later or draft without a profile.
    func buildVoiceProfile(from sentBodies: [String]) async -> VoiceProfile? {
        let cleaned = sentBodies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)
        guard !cleaned.isEmpty else { return nil }

        // Cap each sample so a few long emails don't blow the prompt budget.
        let samples = cleaned.enumerated().map { index, body in
            "Email \(index + 1):\n\(String(body.prefix(1200)))"
        }.joined(separator: "\n\n---\n\n")

        let prompt = """
        Below are emails the user has written. Describe their writing style in \
        2-3 sentences so another writer could imitate it: tone, formality, \
        sentence length, warmth, punctuation habits, emoji use, etc. Also \
        capture their typical greeting and sign-off.

        \(samples)

        Reply with ONLY this JSON:
        {"descriptor":"<2-3 sentence style description>","greeting":"<typical greeting or empty>","signoff":"<typical sign-off or empty>"}
        """
        guard let response = await run(prompt),
              let parsed = MailJSON.decode(VoiceResponse.self, from: response)
        else { return nil }
        let descriptor = parsed.descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !descriptor.isEmpty else { return nil }
        return VoiceProfile(
            descriptor: descriptor,
            greeting: parsed.greeting?.trimmingCharacters(in: .whitespacesAndNewlines),
            signoff: parsed.signoff?.trimmingCharacters(in: .whitespacesAndNewlines),
            builtAt: Date(),
            sampleCount: cleaned.count
        )
    }

    // MARK: - Reminder date fallback

    private struct DateResponse: Decodable { let iso8601: String }

    /// Resolves a fuzzy reminder phrase the deterministic parser couldn't
    /// ("the day after the demo", "early next month") to a concrete date.
    func resolveReminderDate(_ phrase: String, today: String) async -> Date? {
        let prompt = """
        Today is \(today). Convert this reminder timing into a single concrete \
        date-time. If only a day is implied, use 17:00 local. Phrase: "\(phrase)"

        Reply with ONLY this JSON: {"iso8601":"<YYYY-MM-DDThh:mm:ssZ>"}
        """
        guard let response = await run(prompt),
              let parsed = MailJSON.decode(DateResponse.self, from: response)
        else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: parsed.iso8601)
    }

    // MARK: - Helpers

    /// JSON-encodes a string (with surrounding quotes) so it can be embedded
    /// in the one-object-per-line blocks we hand the model.
    private func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the surrounding [ ] from the single-element array.
        return String(array.dropFirst().dropLast())
    }
}
