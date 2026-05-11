import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:). Returns the full text
    /// of one or more highlights the user clipped earlier in the
    /// conversation, resolved by global 1-based index against the chat
    /// session's persisted history.
    func readHighlights(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let content = await readHighlightsContent(call.indices)
        return NativeBrowserToolResult(call: call, succeeded: true, content: content)
    }
}
