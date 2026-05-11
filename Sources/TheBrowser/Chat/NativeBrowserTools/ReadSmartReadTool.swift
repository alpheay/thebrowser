import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:). Returns the currently
    /// displayed Smart Read summary (TL;DR + key points + metadata) when one
    /// is loaded, or a short status string when the panel is idle, still
    /// loading, or in a failed state. Always succeeds — the textual payload
    /// itself communicates whether useful content was available.
    func readSmartRead(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let content = await smartReadContent()
        return NativeBrowserToolResult(call: call, succeeded: true, content: content)
    }
}
