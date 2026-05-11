import Foundation

/// Sweeps obvious secret shapes out of context before it leaves the device.
/// False positives are cheap (we just lose a tiny bit of context); false
/// negatives leak credentials into the model prompt — so the patterns lean
/// permissive.
enum InlineCompletionsRedaction {
    struct Result: Equatable {
        var text: String
        var didRedact: Bool
    }

    static let patterns: [String] = [
        #"\bsk-[A-Za-z0-9_\-]{20,}\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bASIA[0-9A-Z]{16}\b"#,
        #"\bghp_[A-Za-z0-9]{30,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#,
        #"\b(?:\d[ -]?){13,19}\b"#
    ]

    private static let replacement = "[REDACTED]"

    static func redact(_ input: String) -> Result {
        guard !input.isEmpty else { return Result(text: input, didRedact: false) }
        var current = input
        var didRedact = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            let replaced = regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: replacement
            )
            if replaced != current {
                didRedact = true
                current = replaced
            }
        }
        return Result(text: current, didRedact: didRedact)
    }
}
