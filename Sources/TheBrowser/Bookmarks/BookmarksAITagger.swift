import Foundation

/// One AI round-trip producing tags and a short description for a single
/// bookmark. Used both for newly-added bookmarks and the migration
/// backfill. The model is told to return strict JSON so we can parse
/// without any free-text recovery logic.
enum BookmarksAITagger {
    struct Result: Sendable {
        var tags: [String]
        var descriptionText: String
    }

    /// Calls the configured AI provider's fast model with the bookmark's
    /// title + URL + optional page excerpt. The excerpt is best-effort —
    /// `nil` for migrated bookmarks where we don't have the page text.
    static func tag(title: String, url: String, excerpt: String?, modelOverride: String?) async throws -> Result {
        let provider = AIHarnessConfiguration.current().provider
        let resolvedModel = (modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? provider.fastModelID

        let prompt = formatPrompt(title: title, url: url, excerpt: excerpt)
        let response = try await AIProviderClient().ask(
            prompt: prompt,
            systemPromptOverride: systemPrompt,
            modelOverride: resolvedModel
        )

        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return Result(tags: [], descriptionText: "") }

        return parse(cleaned)
    }

    /// Splits the model's JSON response into our struct. Forgives common
    /// stray wrappers (fenced code blocks, leading prose). On total
    /// failure we return an empty result rather than throwing — callers
    /// treat that as "tagging failed silently" per the design spec.
    static func parse(_ raw: String) -> Result {
        let json = extractJSONBlob(from: raw) ?? raw

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return Result(tags: [], descriptionText: "")
        }

        let tags = (object["tags"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .prefix(5)

        let description = (object["description"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Result(tags: Array(tags), descriptionText: description)
    }

    /// Pulls the first `{...}` blob out of a response that may be wrapped
    /// in a fenced code block or chatter. Returns nil if no balanced blob
    /// is found.
    private static func extractJSONBlob(from text: String) -> String? {
        guard let openIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[openIndex...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func formatPrompt(title: String, url: String, excerpt: String?) -> String {
        var lines: [String] = []
        lines.append("Tag this bookmark for a personal browser library. Respond with strict JSON only — no preamble, no code fences, no trailing prose.")
        lines.append("")
        lines.append("Output JSON shape:")
        lines.append("  {")
        lines.append("    \"tags\": [\"<lowercase, 1-2 word topical tag>\", ...],   // 3 to 5 tags, no duplicates, no punctuation")
        lines.append("    \"description\": \"<1-2 plain sentences summarizing what this page is about>\"")
        lines.append("  }")
        lines.append("")
        lines.append("Tag rules:")
        lines.append("- Short, generic topics the user could later filter on (e.g. \"python\", \"design\", \"ml-papers\", \"recipes\").")
        lines.append("- Lowercase. Use hyphens for multi-word tags.")
        lines.append("- Skip overly broad tags like \"web\" or \"article\".")
        lines.append("- Skip the site name unless it is itself the topic.")
        lines.append("")
        lines.append("Description rules:")
        lines.append("- 1-2 short sentences, factual, no marketing language.")
        lines.append("- Do not start with \"This page\" / \"This article\".")
        lines.append("- Plain text — no markdown, no emojis.")
        lines.append("")
        lines.append("Bookmark:")
        lines.append("Title: \(title.isEmpty ? "(no title)" : title)")
        lines.append("URL: \(url)")
        if let excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty {
            lines.append("")
            lines.append("Page excerpt (may be truncated):")
            let capped = excerpt.count > 1_400 ? String(excerpt.prefix(1_400)) + "…" : excerpt
            lines.append(capped)
        }
        return lines.joined(separator: "\n")
    }

    private static let systemPrompt = """
    You generate concise metadata for personal bookmark libraries. Always respond with strict JSON matching the shape requested in the user prompt. Never include preamble, markdown fences, or trailing prose. Avoid emojis.
    """
}
