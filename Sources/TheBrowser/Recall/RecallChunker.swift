import Foundation

/// Splits a captured page's readable text into retrieval-sized passages.
///
/// Chunking matters: embedding and BM25-ranking a whole 4,000-word article as
/// one unit buries the relevant sentence. We pack paragraphs up to a word
/// budget, break over-long paragraphs on sentence boundaries, and carry a
/// lightweight heading so a chunk can answer "what section was that in".
/// Pure and deterministic so it can be unit-tested without a browser.
enum RecallChunker {
    /// Target passage size in words. ~220 words ≈ ~300 tokens — comfortably
    /// inside any on-device embedding model's context and large enough to hold
    /// a coherent idea.
    static let targetWords = 220
    /// Chunks shorter than this are merged into the previous one rather than
    /// stranded alone (a 5-word trailing fragment retrieves poorly).
    static let minWords = 40
    /// Hard ceiling so a single monster paragraph can't blow past the budget.
    static let maxWords = 320

    static func chunks(for text: String) -> [RecallChunkInput] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t\f]+"#, with: " ", options: .regularExpression)
        // Split on blank lines via a sentinel — `components(separatedBy:)`
        // doesn't take a regex, and `\u{1}` won't occur in readable text.
        let paragraphs = normalized
            .replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [RecallChunkInput] = []
        var pendingHeading: String?
        var buffer: [String] = []
        var bufferWords = 0
        var bufferHeading: String?

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n\n")
            // Merge a too-small chunk back into the previous one so we never
            // strand a fragment — unless there's nothing to merge into.
            if bufferWords < minWords, let last = result.last {
                result[result.count - 1] = RecallChunkInput(
                    ordinal: last.ordinal,
                    heading: last.heading,
                    text: last.text + "\n\n" + text,
                    tokenCount: last.tokenCount + bufferWords
                )
            } else {
                result.append(RecallChunkInput(
                    ordinal: result.count,
                    heading: bufferHeading,
                    text: text,
                    tokenCount: bufferWords
                ))
            }
            buffer = []
            bufferWords = 0
            bufferHeading = nil
        }

        for paragraph in paragraphs {
            if let heading = headingText(paragraph) {
                // A heading closes the current chunk and labels the next.
                flush()
                pendingHeading = heading
                continue
            }

            let words = wordCount(paragraph)

            if words > maxWords {
                // Oversized paragraph: flush what we have, then emit it in
                // sentence-packed pieces.
                flush()
                for piece in sentencePack(paragraph) {
                    result.append(RecallChunkInput(
                        ordinal: result.count,
                        heading: pendingHeading,
                        text: piece,
                        tokenCount: wordCount(piece)
                    ))
                    pendingHeading = nil
                }
                continue
            }

            if buffer.isEmpty {
                bufferHeading = pendingHeading
                pendingHeading = nil
            }
            buffer.append(paragraph)
            bufferWords += words
            if bufferWords >= targetWords { flush() }
        }
        flush()

        return result
    }

    // MARK: - Helpers

    /// Treats a short, punctuation-light line as a section heading: under ~14
    /// words, no terminal sentence punctuation, not a list bullet.
    private static func headingText(_ paragraph: String) -> String? {
        guard !paragraph.contains("\n") else { return nil }
        let words = wordCount(paragraph)
        guard words > 0, words <= 14, paragraph.count <= 90 else { return nil }
        let last = paragraph.last!
        if ".!?:,;".contains(last) { return nil }
        if "-•*".contains(paragraph.first ?? " ") { return nil }
        return paragraph
    }

    private static func sentencePack(_ paragraph: String) -> [String] {
        let sentences = splitSentences(paragraph)
        var pieces: [String] = []
        var current: [String] = []
        var currentWords = 0
        for sentence in sentences {
            let words = wordCount(sentence)
            if currentWords + words > targetWords, !current.isEmpty {
                pieces.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        return pieces.isEmpty ? [paragraph] : pieces
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
