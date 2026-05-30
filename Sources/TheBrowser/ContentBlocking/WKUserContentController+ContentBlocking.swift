import WebKit

extension WKUserContentController {
    /// Applies the shared controller's current content-blocking rule lists to
    /// this content controller. Called from `mountWebViewStack` so every tab —
    /// new, resurrected from hibernation, or rebuilt — picks up blocking
    /// without each call site reaching into ``ContentBlockingController``.
    @MainActor
    func applyContentBlocking(from controller: ContentBlockingController = .shared) {
        controller.apply(to: self)
    }
}
