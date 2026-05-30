import Foundation
@preconcurrency import WebKit

/// Compiles ``BlockList``s into `WKContentRuleList`s via WebKit's on-device
/// rule-list store. Compilation is the expensive step — WebKit turns the JSON
/// into a bytecode matcher — so results are cached inside the store, keyed by
/// identifier, and only recompiled when the identifier changes.
///
/// The per-site allowlist is woven in *here*, not in the catalog: every rule's
/// trigger gains an `unless-domain` clause for the allowlisted sites just
/// before encoding. That keeps the catalog pure static data and turns a
/// site-allow toggle into a recompile rather than a rebuild of rule objects.
@MainActor
final class ContentRuleCompiler {
    private let store: WKContentRuleListStore

    init(store: WKContentRuleListStore = .default()) {
        self.store = store
    }

    enum CompileError: Error {
        case encodingFailed
        /// WebKit returned neither a list nor an error — treat as a failure
        /// for this list so the caller can skip it.
        case emptyResult
    }

    /// Compiles a single list into a `WKContentRuleList`. Throws on encode or
    /// WebKit compile failure so the caller can skip just this one list and
    /// keep the rest.
    func compile(_ list: BlockList, allowlistPatterns: [String]) async throws -> WKContentRuleList {
        let json = try Self.encode(list.rules, unlessDomain: allowlistPatterns)
        let identifier = Self.cacheIdentifier(for: list, allowlistPatterns: allowlistPatterns)
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: CompileError.emptyResult)
                }
            }
        }
    }

    /// Encodes rules to the JSON array string WebKit's compiler expects,
    /// injecting `unlessDomain` patterns onto every trigger. Existing
    /// per-rule `unless-domain` entries are merged, not clobbered.
    /// `nonisolated` — pure data work, no WebKit, callable off the main actor.
    nonisolated static func encode(_ rules: [BlockRule], unlessDomain patterns: [String]) throws -> String {
        let prepared: [BlockRule] = patterns.isEmpty ? rules : rules.map { rule in
            var copy = rule
            copy.trigger.unlessDomain = (copy.trigger.unlessDomain ?? []) + patterns
            return copy
        }
        let data = try JSONEncoder().encode(prepared)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CompileError.encodingFailed
        }
        return json
    }

    /// The store key for a list. Folding the allowlist into the identifier
    /// means a changed allowlist misses the cache and recompiles, while an
    /// unchanged one is served instantly from WebKit's store.
    nonisolated static func cacheIdentifier(for list: BlockList, allowlistPatterns: [String]) -> String {
        guard !allowlistPatterns.isEmpty else { return list.id }
        // Order-independent, launch-stable suffix. Avoids `Hasher`, whose seed
        // is randomized per process and would defeat the on-disk cache.
        let suffix = allowlistPatterns.sorted().joined(separator: ",")
        return "\(list.id)#\(djb2(suffix))"
    }

    nonisolated private static func djb2(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return String(hash, radix: 36)
    }
}
