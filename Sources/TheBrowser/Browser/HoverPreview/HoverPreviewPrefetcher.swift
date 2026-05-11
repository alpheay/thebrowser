import Foundation

/// Coordinates background prefetch tasks for hover preview. Caps in-flight
/// fetches at ``maxConcurrent`` and skips work when the system is on
/// battery + Low Power Mode or when the URL host matches the user's
/// blocklist.
@MainActor
final class HoverPreviewPrefetcher {
    var maxConcurrent: Int = 4

    /// Newline-separated host patterns. `*.example.com` matches any
    /// subdomain. Bare `example.com` matches the eTLD+1 and any subdomain.
    var blocklist: [String] = []

    private weak var cache: HoverPreviewCache?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var battery: BatteryMonitor = .shared

    init(cache: HoverPreviewCache) {
        self.cache = cache
    }

    func updateBlocklist(_ raw: String) {
        blocklist = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Queues a background fetch if the URL isn't already cached, the user
    /// hasn't blocked the host, the battery monitor allows it, and we
    /// aren't already at capacity. Silent no-op otherwise — prefetches are
    /// best-effort.
    func prefetch(_ url: URL) {
        guard let cache else { return }
        if cache.contains(url) { return }
        if isBlocked(url: url) { return }
        if battery.shouldDeferBackgroundWork { return }
        let key = url.absoluteString
        if inFlight[key] != nil { return }
        if inFlight.count >= maxConcurrent { return }

        let task = Task<Void, Never> { @MainActor [weak self] in
            defer { self?.inFlight.removeValue(forKey: key) }
            do {
                let content = try await HoverPreviewFetcher.fetch(url: url)
                guard !Task.isCancelled else { return }
                self?.cache?.setContent(content, for: url)
            } catch {
                // Prefetch failures are silent. The on-demand peek path will
                // surface the same error if the user actually opens it.
            }
        }
        inFlight[key] = task
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    func isBlocked(url: URL) -> Bool {
        guard !blocklist.isEmpty, let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        for pattern in blocklist {
            if matches(host: host, pattern: pattern) { return true }
        }
        return false
    }

    private func matches(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}
