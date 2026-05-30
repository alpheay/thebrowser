import Foundation

/// Pure popup-blocking decision logic. WebKit-specific callers translate their
/// navigation action into these plain inputs so this stays easy to test.
enum PopupBlockingPolicy {
    static func shouldBlock(
        isEnabled: Bool,
        openerHost: String?,
        targetHost: String?,
        isUserActivated: Bool,
        allowList: SiteAllowList
    ) -> Bool {
        guard isEnabled else { return false }

        if let openerHost, allowList.contains(openerHost) {
            return false
        }
        if openerHost == nil, let targetHost, allowList.contains(targetHost) {
            return false
        }

        return !isUserActivated
    }
}
