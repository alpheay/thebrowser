import Foundation

/// Heuristic question detection for search queries. Flags a query as a
/// question when the user is likely asking something Q&A-style — even
/// without a trailing "?" — so the search results view can surface an
/// inline AI answer card.
///
/// The detector is intentionally conservative: a single-word query like
/// "weather" or a noun phrase like "iphone 15 review" returns false, while
/// queries that read as natural-language asks ("how to install python",
/// "is the sky blue", "react vs vue") return true.
enum QuestionDetector {
    static func isQuestion(_ raw: String) -> Bool {
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return false }

        if text.contains("?") { return true }

        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 2 else { return false }

        for pattern in patterns {
            if matches(text, pattern: pattern) { return true }
        }
        return false
    }

    /// Patterns ordered from most → least confident. Anchored where a sentence
    /// position carries meaning (e.g. interrogatives only count at the start).
    private static let patterns: [String] = [
        // Wh- interrogatives at start.
        #"^(what(?:'s|s)?|why|how|when|where|who(?:m|se)?|which|whose)\b"#,

        // Inquisitive openers — natural language asks for explanation.
        #"^(tell\s+me|explain|define|describe|summari[sz]e|compare|i\s+wonder|i\s+want\s+to\s+know|please\s+explain|give\s+me\s+(?:a|an|the)?)\b"#,

        // "How to" / "How do" prefix even when "how" is followed by another verb.
        #"^how\s+(to|do|does|did|can|could|should|might|would|will)\b"#,

        // Auxiliary-led yes/no questions: "is the sky blue", "can dogs fly".
        // Require subject + at least one more token so phrases like "is android"
        // alone don't trigger; minimum three words total.
        #"^(is|are|was|were|am|do|does|did|can|could|would|should|will|shall|may|might|must|has|have|had)\s+\w+\s+\w+"#,

        // Comparison "X vs Y" / "X versus Y".
        #"\b(vs\.?|versus)\b"#,

        // "meaning of …", "definition of …", "difference between …".
        #"\b(meaning|definition)\s+of\b"#,
        #"\bdifference\s+between\b"#
    ]

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
