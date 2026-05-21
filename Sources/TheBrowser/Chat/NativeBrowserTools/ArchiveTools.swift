import Foundation

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point - call via execute(_:).
    func archiveQuery(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let limit = min(max(call.maxResults ?? 20, 1), 100)
        let since = call.sinceTs.flatMap(PageArchive.parseTimestamp)
        let visits = await queryArchive(call.url, since, limit)

        let content: String
        if visits.isEmpty {
            content = "No archived visits matched the query."
        } else {
            content = visits.map { visit in
                """
                Visit ID: \(visit.id)
                URL: \(visit.url)
                Title: \(visit.title.isEmpty ? "(untitled)" : visit.title)
                Timestamp: \(Self.timestampString(visit.timestamp))
                DOM blob: \(visit.domBlobHash)
                Screenshot blob: \(visit.screenshotBlobHash)
                Network rows: \(visit.networkLogCount)
                """
            }.joined(separator: "\n\n")
        }

        return NativeBrowserToolResult(
            call: call,
            succeeded: true,
            content: content
        )
    }

    /// Dispatcher entry point - call via execute(_:).
    func archiveGet(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        guard let visitID = call.visitID else {
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "archive.get requires visit_id."
            )
        }
        guard let details = await getArchiveVisit(visitID) else {
            return NativeBrowserToolResult(
                call: call,
                succeeded: false,
                content: "No archived visit exists with ID \(visitID)."
            )
        }

        let network = details.networkLog.isEmpty
            ? "No observed network rows."
            : details.networkLog.map(Self.networkLogText).joined(separator: "\n")

        return NativeBrowserToolResult(
            call: call,
            succeeded: true,
            content: """
            Visit ID: \(details.visit.id)
            URL: \(details.visit.url)
            Title: \(details.visit.title.isEmpty ? "(untitled)" : details.visit.title)
            Timestamp: \(Self.timestampString(details.visit.timestamp))
            Screenshot: \(details.screenshotURL.path)

            DOM:
            \(details.domHTML)

            Network log:
            \(network)
            """
        )
    }

    private static func networkLogText(_ entry: PageArchiveNetworkLogEntry) -> String {
        let status = entry.status.map(String.init) ?? "n/a"
        let duration = entry.durationMS.map { String(format: "%.1fms", $0) } ?? "n/a"
        let body = entry.bodyBlobHash.map { " body:\($0)" } ?? ""
        return "- \(entry.method) \(entry.url) status:\(status) type:\(entry.type) duration:\(duration)\(body)"
    }

    private static func timestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
