import Foundation

/// A named, categorized bundle of ``BlockRule``s with a stable identifier. One
/// list compiles into one `WKContentRuleList`.
///
/// Lists are the modular unit the catalog produces and the compiler consumes.
/// Keeping them plain value types makes them trivial to build, unit-test, and
/// diff — no list ever reaches for global state.
struct BlockList: Identifiable, Equatable {
    /// Stable identifier, reused as the `WKContentRuleList` identifier and as
    /// the on-disk compile-cache key. Must be unique across all lists.
    let id: String
    /// Short human-facing name shown in Settings (e.g. "Ad Networks").
    let name: String
    let category: BlockListCategory
    /// Where the rules came from — "Bundled", a URL, etc. Surfaced in the UI
    /// so the user can see what's active and why.
    let source: String
    let rules: [BlockRule]

    var ruleCount: Int { rules.count }
}
