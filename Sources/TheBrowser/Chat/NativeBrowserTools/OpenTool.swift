import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func open(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let url = NativeBrowserToolURL.url(from: call.rawInput) else {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "Invalid URL: \(call.rawInput)")
        }

        await MainActor.run {
            openURL(url)
        }

        return NativeBrowserToolResult(call: call, succeeded: true, content: "Opened \(url.absoluteString) in the current tab.")
    }
}
