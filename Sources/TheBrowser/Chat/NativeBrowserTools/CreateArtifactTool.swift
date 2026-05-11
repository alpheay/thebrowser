import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point — call via execute(_:).
    func createArtifact(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let html = call.html, !html.isEmpty else {
            return NativeBrowserToolResult(call: call, succeeded: false, content: "create_artifact requires an `html` field with the full document body.")
        }
        let title = call.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Artifact"
        do {
            let url = try await saveAndOpenArtifact(title, html)
            return NativeBrowserToolResult(
                call: call,
                succeeded: true,
                content: "Artifact saved to \(url.path) and opened in a new tab.",
                artifactURL: url
            )
        } catch {
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "Failed to save artifact: \(error.localizedDescription)"
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
