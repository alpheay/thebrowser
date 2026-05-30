import Foundation

/// The intelligent-inbox "brain": a `Sendable` value that wraps
/// `AIProviderClient` and exposes one method per reasoning task. Every method
/// is a single one-shot call on a FAST model (gpt-5.4-mini via codex /
/// claude-haiku-4-5 via claude), decoded through `MailJSON` so small-model
/// prose/fence wrapping doesn't break parsing, and degrading to `nil`/identity
/// on any failure. It is completely decoupled from the 25-iteration chat loop —
/// cheap, parallelizable, and unit-friendly.
struct MailAgent: Sendable {
    /// Isolated workspace for the sub-agent CLI subprocess.
    var workspace: URL

    init(workspace: URL) {
        self.workspace = workspace
    }

    /// Provider the sub-agent runs on: an explicit Mail override, else the main
    /// chat provider, else codex. Read live so settings changes take effect.
    var provider: AIProviderKind {
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: PreferenceKey.mailSubagentProvider),
           let explicit = AIProviderKind(rawValue: override) {
            return explicit
        }
        let main = defaults.string(forKey: PreferenceKey.aiProvider) ?? ""
        return AIProviderKind(rawValue: main) ?? .codex
    }

    /// Model id: an explicit Mail override, else the provider's fast model.
    var model: String {
        let override = UserDefaults.standard.string(forKey: PreferenceKey.mailSubagentModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? provider.fastModelID : override
    }

    // MARK: - Core transport

    private func run(system: String, prompt: String, reasoning: String = "") async -> String? {
        do {
            return try await AIProviderClient().complete(
                prompt: prompt,
                provider: provider,
                model: model,
                systemPrompt: system,
                workspace: workspace,
                reasoningEffort: reasoning
            )
        } catch {
            return nil
        }
    }

    // MARK: - Triage

    func classify(_ inputs: [TriageInput], labels: [AILabel], examples: [TriageExample]) async -> [TriageDecision] {
        guard !inputs.isEmpty, !labels.isEmpty else { return [] }

        let labelLines = labels.map { "- \($0.name): \($0.descriptionText)" }.joined(separator: "\n")
        var exampleBlock = ""
        if !examples.isEmpty {
            let lines = examples.suffix(20).map {
                "- from \($0.fromAddress), subject \"\($0.subject)\" → \($0.label)"
            }.joined(separator: "\n")
            exampleBlock = "\nLearned examples from the user's past corrections (weight these heavily):\n\(lines)\n"
        }
        let messageLines = inputs.map {
            "{\"messageID\":\"\($0.messageID)\",\"from\":\"\($0.fromName) <\($0.fromAddress)>\",\"subject\":\"\(escape($0.subject))\",\"snippet\":\"\(escape(String($0.snippet.prefix(280))))\"}"
        }.joined(separator: "\n")

        let system = "You are a precise email triage classifier. You only output JSON."
        let prompt = """
        Classify each email into exactly ONE of these labels by name:
        \(labelLines)
        \(exampleBlock)
        For each message, judge by sender (real person vs automated), whether it needs a reply, and the label descriptions. If you are not confident, set a low confidence and you may use "Other".

        Messages:
        \(messageLines)

        Return ONLY a JSON array, one object per message, no prose:
        [{"messageID":"<id>","label":"<one label name>","confidence":<0.0-1.0>}]
        """
        guard let text = await run(system: system, prompt: prompt) else { return [] }
        return MailJSON.decode([TriageDecision].self, from: text) ?? []
    }

    // MARK: - Drafting

    func draft(
        threadText: String,
        instructions: String?,
        suggestedSubject: String?,
        recipient: String,
        voice: VoiceProfile,
        memories: [MailMemory],
        style: String?
    ) async -> DraftContent? {
        let voiceBlock = voice.isUsable
            ? "Write in THIS person's voice: \(voice.descriptor)\(voice.signature.map { " Sign off like: \($0)." } ?? "")"
            : "Write in a natural, concise, professional voice."
        let memoryBlock = memories.isEmpty ? "" : "\nRelevant facts/preferences to honor:\n" + memories.map { "- \($0.text)" }.joined(separator: "\n")
        let styleBlock = style.map { "\nTone for this recipient: \($0)." } ?? ""
        let intent = (instructions?.isEmpty == false) ? instructions! : "Write an appropriate reply that moves the conversation forward."

        let system = "You are an email-writing assistant. You write the email body only — no preamble, no explanation. Output JSON."
        let prompt = """
        \(voiceBlock)\(styleBlock)\(memoryBlock)

        Recipient: \(recipient)
        Goal/instruction: \(intent)

        Thread context (most recent last):
        \(String(threadText.prefix(8_000)))

        Write the reply. Do not include a subject line in the body. Keep it tight and human — no corporate filler.
        Return ONLY JSON: {"subject":"<subject or empty to keep the thread subject>","body":"<the email body>"}
        """
        guard let text = await run(system: system, prompt: prompt) else { return nil }
        return MailJSON.decode(DraftContent.self, from: text)
    }

    func editDraft(
        _ body: String,
        action: DraftEditAction,
        customInstruction: String?,
        threadText: String?,
        voice: VoiceProfile
    ) async -> String? {
        let directive: String
        switch action {
        case .improve: directive = "Improve clarity, flow, and warmth while keeping the meaning and roughly the same length."
        case .shorten: directive = "Make it noticeably shorter and punchier without losing the key points."
        case .lengthen: directive = "Expand it with a bit more context and warmth, staying on-topic."
        case .fixGrammar: directive = "Fix only grammar, spelling, and punctuation. Do not change tone or content."
        case .custom: directive = customInstruction?.isEmpty == false ? customInstruction! : "Improve the draft."
        }
        let voiceBlock = voice.isUsable ? "\nKeep the author's voice: \(voice.descriptor)" : ""
        let contextBlock = (threadText?.isEmpty == false) ? "\nThread context:\n\(String(threadText!.prefix(4_000)))" : ""

        let system = "You are an email editor. You return the edited body only, as JSON."
        let prompt = """
        Edit instruction: \(directive)\(voiceBlock)\(contextBlock)

        Current draft body:
        \(body)

        Return ONLY JSON: {"body":"<the edited body>"}
        """
        guard let text = await run(system: system, prompt: prompt) else { return nil }
        return MailJSON.decode(BodyDTO.self, from: text)?.body
    }

    func rateDraft(_ body: String, goalHint: String?, threadText: String?) async -> DraftRating? {
        let goalBlock = goalHint.map { "Stated goal: \($0)\n" } ?? ""
        let contextBlock = (threadText?.isEmpty == false) ? "Thread context:\n\(String(threadText!.prefix(4_000)))\n" : ""
        let system = "You are a sharp writing coach for email. Output JSON only."
        let prompt = """
        \(goalBlock)\(contextBlock)Draft to evaluate:
        \(body)

        Infer the goal of this email, score how effectively it achieves that goal, and list concrete issues + suggestions.
        Return ONLY JSON: {"inferredGoal":"...","score":<0-100>,"issues":["..."],"suggestions":["..."]}
        """
        guard let text = await run(system: system, prompt: prompt) else { return nil }
        return MailJSON.decode(DraftRating.self, from: text)
    }

    // MARK: - Search

    func translateQuery(_ natural: String, today: Date) async -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let todayStr = formatter.string(from: today)
        let system = "You translate natural-language email requests into Gmail search syntax. Output JSON only."
        let prompt = """
        Today is \(todayStr). Translate this request into a single Gmail search query string using Gmail operators (from:, to:, subject:, newer_than:, older_than:, after:, before:, is:unread, has:attachment, label:, "exact phrase", OR, -). Do not invent senders. Prefer newer_than:/older_than: for relative dates.

        Request: \(natural)

        Return ONLY JSON: {"query":"<gmail query>"}
        """
        guard let text = await run(system: system, prompt: prompt) else { return nil }
        let q = MailJSON.decode(QueryDTO.self, from: text)?.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (q?.isEmpty == false) ? q : nil
    }

    /// Reranks search hits by relevance to the natural-language intent,
    /// returning ids best-first. Appends any ids it dropped so nothing is lost.
    func rerank(_ natural: String, hits: [MailSearchHit]) async -> [String] {
        guard hits.count > 2 else { return hits.map(\.id) }
        let lines = hits.prefix(20).map {
            "{\"id\":\"\($0.id)\",\"from\":\"\(escape($0.fromName))\",\"subject\":\"\(escape($0.subject))\",\"snippet\":\"\(escape(String($0.snippet.prefix(160))))\"}"
        }.joined(separator: "\n")
        let system = "You rank emails by relevance. Output JSON only."
        let prompt = """
        Intent: \(natural)

        Candidates:
        \(lines)

        Return ONLY JSON with message ids ordered most-relevant first: {"ids":["<id>", "..."]}
        """
        guard let text = await run(system: system, prompt: prompt),
              let ranked = MailJSON.decode(IDsDTO.self, from: text)?.ids else {
            return hits.map(\.id)
        }
        let valid = Set(hits.map(\.id))
        var ordered = ranked.filter { valid.contains($0) }
        for hit in hits where !ordered.contains(hit.id) { ordered.append(hit.id) }
        return ordered
    }

    // MARK: - Summaries / memories / voice / risk

    func summarizeThread(_ threadText: String) async -> String? {
        let system = "You summarize email threads tightly. Output JSON only."
        let prompt = """
        Summarize this email thread in 2–4 sentences, capturing who wants what and any open action items.

        \(String(threadText.prefix(10_000)))

        Return ONLY JSON: {"summary":"..."}
        """
        guard let text = await run(system: system, prompt: prompt) else { return nil }
        return MailJSON.decode(SummaryDTO.self, from: text)?.summary
    }

    func extractMemories(fromThread threadText: String, contactEmail: String?) async -> [MailMemory] {
        let anchorHint = contactEmail.map { "Default anchor for facts about the other person: email:\($0)." } ?? "Use anchor \"always\" for facts about the user."
        let system = "You extract durable, useful memories from email. Output JSON only. Be conservative — only clear, lasting facts/preferences/commitments."
        let prompt = """
        Extract up to 3 durable memories from this thread. \(anchorHint)
        kinds: aboutMe (the user's own preferences/rules), aboutEntity (facts about the other person/company), todo (a commitment the user made), snippet (a reusable phrase). Skip anything trivial or one-off.

        Thread:
        \(String(threadText.prefix(8_000)))

        Return ONLY JSON: [{"text":"...","kind":"aboutEntity","anchor":"email:foo@bar.com"}]
        """
        guard let text = await run(system: system, prompt: prompt),
              let dtos = MailJSON.decode([MemoryDTO].self, from: text) else { return [] }
        return dtos.prefix(3).map { dto in
            MailMemory(
                text: dto.text,
                kind: MailMemoryKind(rawValue: dto.kind ?? "") ?? .aboutEntity,
                anchor: MailMemoryAnchor.parse(dto.anchor ?? "always")
            )
        }
    }

    func buildVoiceProfile(fromSent bodies: [String]) async -> VoiceProfile? {
        guard !bodies.isEmpty else { return nil }
        let samples = bodies.prefix(10).enumerated()
            .map { "Sample \($0.offset + 1):\n\(String($0.element.prefix(800)))" }
            .joined(separator: "\n\n")
        let system = "You analyze writing style from email samples. Output JSON only."
        let prompt = """
        From these emails the user wrote, describe their writing voice in one or two sentences (tone, formality, sentence length, quirks), and capture their typical greeting and sign-off if consistent.

        \(samples)

        Return ONLY JSON: {"descriptor":"...","greeting":"<or empty>","signature":"<or empty>"}
        """
        guard let text = await run(system: system, prompt: prompt),
              let dto = MailJSON.decode(VoiceDTO.self, from: text) else { return nil }
        return VoiceProfile(
            descriptor: dto.descriptor,
            greeting: dto.greeting?.isEmpty == false ? dto.greeting : nil,
            signature: dto.signature?.isEmpty == false ? dto.signature : nil,
            sampleCount: bodies.count,
            updatedAt: Date()
        )
    }

    func assessSendRisk(to recipient: String, subject: String, body: String, isExternal: Bool) async -> SendRisk {
        let system = "You assess whether an email is safe to auto-send. Output JSON only."
        let prompt = """
        Decide if this email is LOW risk (routine, friendly, clearly fine to send automatically) or HIGH risk (sensitive, negotiation, legal/financial commitment, apology, addressed to someone important, or anything a person should review). When in doubt, choose high.

        To: \(recipient) (\(isExternal ? "external" : "internal") recipient)
        Subject: \(subject)
        Body:
        \(String(body.prefix(4_000)))

        Return ONLY JSON: {"risk":"low|high","reason":"<short>"}
        """
        guard let text = await run(system: system, prompt: prompt),
              let dto = MailJSON.decode(RiskDTO.self, from: text) else {
            return .high(reason: "Couldn't assess risk; defaulting to manual review.")
        }
        return dto.risk.lowercased() == "low" ? .low : .high(reason: dto.reason ?? "Flagged for review.")
    }

    // MARK: - Inline autocomplete

    /// A short continuation of the in-progress draft for inline ghost text.
    /// Kept deliberately small + low-effort so it returns fast.
    func autocomplete(threadText: String, recipient: String?, draftSoFar: String, memories: [MailMemory]) async -> String? {
        let memoryBlock = memories.isEmpty ? "" : "Facts to honor: " + memories.prefix(4).map(\.text).joined(separator: "; ") + "\n"
        let recipientBlock = recipient.map { "Recipient: \($0)\n" } ?? ""
        let system = "You complete the user's in-progress email. Continue from the cursor with a short, natural continuation (a few words to one sentence). Output JSON only. Never repeat what's already written."
        let prompt = """
        \(recipientBlock)\(memoryBlock)Thread context:
        \(String(threadText.prefix(2_500)))

        The user's draft so far (continue directly from the end, matching their voice; do not add a greeting if one exists):
        \(String(draftSoFar.suffix(1_200)))

        Return ONLY JSON: {"completion":"<short continuation, may start with a space>"}
        """
        guard let text = await run(system: system, prompt: prompt, reasoning: "low") else { return nil }
        let completion = MailJSON.decode(CompletionDTO.self, from: text)?.completion
        return (completion?.isEmpty == false) ? completion : nil
    }

    // MARK: - Helpers

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Risk verdict for the auto-send gate.
enum SendRisk: Sendable, Equatable {
    case low
    case high(reason: String)

    var isLow: Bool { if case .low = self { return true }; return false }
    var reason: String? { if case .high(let r) = self { return r }; return nil }
}

// MARK: - Decoding DTOs for small-model JSON

private struct BodyDTO: Decodable { let body: String }
private struct QueryDTO: Decodable { let query: String }
private struct IDsDTO: Decodable { let ids: [String] }
private struct SummaryDTO: Decodable { let summary: String }
private struct VoiceDTO: Decodable { let descriptor: String; let greeting: String?; let signature: String? }
private struct MemoryDTO: Decodable { let text: String; let kind: String?; let anchor: String? }
private struct RiskDTO: Decodable { let risk: String; let reason: String? }
private struct CompletionDTO: Decodable { let completion: String }
