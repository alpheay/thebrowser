import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func readTabs(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let content = await readTabsContent(call.indices)
        return NativeBrowserToolResult(call: call, succeeded: true, content: content)
    }
}
