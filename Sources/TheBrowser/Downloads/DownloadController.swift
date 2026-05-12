import AppKit
import Combine
import Foundation
@preconcurrency import WebKit

/// Common surface every in-flight download exposes to ``DownloadController``.
/// Two implementations: ``DownloadSession`` wraps a ``WKDownload`` (the
/// normal browser-initiated path) and ``URLSessionDownloadSession`` is the
/// retry-from-scratch fallback when no resumeData is available.
@MainActor
protocol AnyDownloadSession: AnyObject {
    var id: String { get }
    var bytesReceived: Int64 { get }
    var bytesTotal: Int64? { get }
    var canRetry: Bool { get }

    func cancel(reason: DownloadSession.CancelReason)
    func pause()
    func resume()
    func retry()
}

/// App-wide singleton that owns every active ``WKDownload`` and mirrors them
/// into the persistent ``DownloadsStore``. The popover and toolbar badge
/// observe ``records`` (newest first) and ``activeCount`` to render their
/// live state. ``BrowserTab`` hands new downloads here via
/// ``adopt(_:source:)``.
@MainActor
final class DownloadController: NSObject, ObservableObject {
    static let shared = DownloadController()

    /// Combined list of in-flight + recent rows. Active rows live in memory
    /// until terminal; historical rows come from ``DownloadsStore`` so the
    /// list survives quits.
    @Published private(set) var records: [DownloadRecord] = []

    /// Convenience for badge/ring rendering — number of rows currently
    /// pending, active, or paused.
    @Published private(set) var activeCount: Int = 0

    /// Aggregate progress (0…1) of the in-flight set, weighted by total
    /// bytes when known. Used by the toolbar's badge progress ring.
    @Published private(set) var aggregateProgress: Double = 0

    private let store: DownloadsStore
    private var sessions: [String: any AnyDownloadSession] = [:]
    nonisolated(unsafe) private var storeObserver: NSObjectProtocol?

    init(store: DownloadsStore = DownloadsStore.shared) {
        self.store = store
        super.init()
        store.markInFlightAsInterrupted()
        reload()
        storeObserver = NotificationCenter.default.addObserver(
            forName: DownloadsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - WK integration

    /// Called from ``BrowserTab``'s navigation/response delegates when WK
    /// hands us a `WKDownload`. ``source`` records the originating URL —
    /// the download object itself only exposes `originalRequest` on the
    /// initial setup leg, and that's already what we capture.
    func adopt(_ download: WKDownload, sourceURL: URL?, suggestedMIME: String?) {
        let id = UUID().uuidString
        let origin = sourceURL ?? download.originalRequest?.url

        let record = DownloadRecord(
            id: id,
            url: origin?.absoluteString ?? "",
            filename: "",
            destinationPath: "",
            mimeType: suggestedMIME ?? "",
            startedAt: Date(),
            completedAt: nil,
            bytesReceived: 0,
            bytesTotal: nil,
            state: .pending,
            errorMessage: nil
        )
        store.createDownload(record)

        let session = DownloadSession(
            id: id,
            download: download,
            controller: self
        )
        sessions[id] = session
        download.delegate = session
        reload()
    }

    // MARK: - User actions

    func cancel(id: String) {
        guard let session = sessions[id] else { return }
        session.cancel(reason: .userCancelled)
    }

    func pause(id: String) {
        guard let session = sessions[id] else { return }
        session.pause()
    }

    func resume(id: String) {
        guard let session = sessions[id] else { return }
        session.resume()
    }

    /// Re-attempts a failed download. Uses the prior session's resumeData
    /// when present; otherwise issues a fresh request against the original
    /// URL. Either path takes the row off the failed pile.
    func retry(id: String) {
        if let session = sessions[id], session.canRetry {
            session.retry()
            return
        }
        guard let original = records.first(where: { $0.id == id }),
              let url = URL(string: original.url) else { return }
        // No resumeData — spin up a URLSession-backed download from scratch
        // under a new ID, and remove the old failed row so the popover
        // doesn't show two entries for the same logical attempt.
        let newID = UUID().uuidString
        let fresh = DownloadRecord(
            id: newID,
            url: original.url,
            filename: original.filename,
            destinationPath: original.destinationPath,
            mimeType: original.mimeType,
            startedAt: Date(),
            completedAt: nil,
            bytesReceived: 0,
            bytesTotal: nil,
            state: .pending,
            errorMessage: nil
        )
        store.createDownload(fresh)
        let session = URLSessionDownloadSession(
            id: newID,
            url: url,
            controller: self
        )
        sessions[newID] = session
        session.start()
        store.removeFromList(id: original.id)
        reload()
    }

    func removeFromList(id: String) {
        if let session = sessions[id] {
            session.cancel(reason: .userCancelled)
            sessions.removeValue(forKey: id)
        }
        store.removeFromList(id: id)
        reload()
    }

    func clearCompleted() {
        store.clearCompleted()
        reload()
    }

    /// Wipes finished/failed/cancelled rows. Invoked at quit when the
    /// matching preference is on — see ``TheBrowserApp``.
    func clearCompletedOnQuit() {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.downloadsClearOnQuit) else { return }
        store.clearCompleted()
    }

    /// Reveals the destination file in Finder if it still exists, otherwise
    /// posts a toast.
    func showInFinder(id: String) {
        guard let record = records.first(where: { $0.id == id }),
              !record.destinationPath.isEmpty else { return }
        let url = URL(fileURLWithPath: record.destinationPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            AppNotificationCenter.shared.post(
                title: "File missing",
                message: "\(record.filename) is no longer at its saved location.",
                icon: "questionmark.folder",
                kind: .warning
            )
        }
    }

    /// Opens the destination file with the system default app for its type.
    func openFile(id: String) {
        guard let record = records.first(where: { $0.id == id }),
              !record.destinationPath.isEmpty else { return }
        let url = URL(fileURLWithPath: record.destinationPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            AppNotificationCenter.shared.post(
                title: "File missing",
                message: "\(record.filename) is no longer at its saved location.",
                icon: "questionmark.folder",
                kind: .warning
            )
        }
    }

    // MARK: - Session callbacks

    /// Called by ``DownloadSession`` once WK decides the final destination,
    /// before bytes begin flowing. Updates the persisted row with the real
    /// filename and path so the UI no longer shows an empty filename.
    func sessionDidResolveDestination(id: String, destination: URL) {
        store.updateDestination(id: id, destinationPath: destination.path, filename: destination.lastPathComponent)
        store.updateState(id: id, state: .active)
        reload()
    }

    func sessionDidUpdateProgress(id: String, bytesReceived: Int64, bytesTotal: Int64?) {
        // KVO on `Progress.completedUnitCount` fires per byte. We patch the
        // in-memory ``records`` directly and batch the SQLite write to once
        // per second so the database isn't hit on every chunk.
        updateInMemoryProgress(id: id, bytesReceived: bytesReceived, bytesTotal: bytesTotal)
        schedulePersist(id: id)
    }

    private var pendingPersistIDs: Set<String> = []
    private var persistDebounceTask: Task<Void, Never>?

    private func schedulePersist(id: String) {
        pendingPersistIDs.insert(id)
        guard persistDebounceTask == nil else { return }
        persistDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            let ids = self.pendingPersistIDs
            self.pendingPersistIDs.removeAll()
            self.persistDebounceTask = nil
            for id in ids {
                guard let record = self.records.first(where: { $0.id == id }) else { continue }
                self.store.updateProgress(
                    id: id,
                    bytesReceived: record.bytesReceived,
                    bytesTotal: record.bytesTotal
                )
            }
        }
    }

    func sessionDidComplete(id: String, bytesReceived: Int64) {
        store.markCompleted(id: id, bytesReceived: bytesReceived)
        let record = records.first(where: { $0.id == id })
        let filename = record?.filename ?? "Download"
        AppNotificationCenter.shared.post(
            title: "Download complete",
            message: filename,
            icon: "arrow.down.circle.fill",
            kind: .success,
            actionLabel: "Show in Finder",
            action: { [weak self] in self?.showInFinder(id: id) }
        )
        sessions.removeValue(forKey: id)
        reload()
    }

    func sessionDidFail(id: String, message: String, retryable: Bool) {
        store.markFailed(id: id, errorMessage: message)
        let record = records.first(where: { $0.id == id })
        let filename: String = {
            if let trimmed = record?.filename.nilIfEmpty {
                return trimmed
            }
            if let tail = record?.url.split(separator: "/").last {
                return String(tail)
            }
            return "Download"
        }()
        let retryAction: (@MainActor () -> Void)? = retryable
            ? { @MainActor [weak self] in self?.retry(id: id) }
            : nil
        AppNotificationCenter.shared.post(
            title: "Download failed",
            message: filename,
            icon: "exclamationmark.triangle.fill",
            kind: .error,
            actionLabel: retryable ? "Retry" : nil,
            action: retryAction
        )
        // Keep the session in the map only when there's resumeData; clearing
        // it would lose the only retry path.
        if !retryable {
            sessions.removeValue(forKey: id)
        }
        reload()
    }

    func sessionDidPause(id: String) {
        store.updateState(id: id, state: .paused)
        reload()
    }

    func sessionDidResume(id: String) {
        store.updateState(id: id, state: .active)
        reload()
    }

    func sessionDidCancel(id: String) {
        store.updateState(id: id, state: .cancelled)
        sessions.removeValue(forKey: id)
        reload()
    }

    // MARK: - Destination resolution

    /// Resolves the destination URL for a freshly-starting download. Honors
    /// the "Ask where to save each file" preference by surfacing an
    /// NSSavePanel; otherwise picks a non-clashing name inside the
    /// configured downloads folder. Returns nil when the user cancels the
    /// save panel.
    func resolveDestination(suggestedFilename: String) -> URL? {
        let defaults = UserDefaults.standard
        let ask = defaults.bool(forKey: PreferenceKey.downloadsAskWhereToSave)
        let folder = resolvedDownloadsFolder()

        if ask {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.nameFieldStringValue = suggestedFilename
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return nil }
            return url
        }

        return uniqueDestination(in: folder, suggestedFilename: suggestedFilename)
    }

    func resolvedDownloadsFolder() -> URL {
        let path = UserDefaults.standard.string(forKey: PreferenceKey.downloadsFolderPath) ?? ""
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let fallback = URL(fileURLWithPath: AppDefaults.defaultDownloadsFolderPath())
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Picks `name.ext`, then `name (2).ext`, `name (3).ext`, … until a
    /// non-existing path is found. Mirrors macOS Finder's collision suffix.
    private func uniqueDestination(in folder: URL, suggestedFilename: String) -> URL {
        let trimmed = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "download" : trimmed
        let nsName = fallback as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        let manager = FileManager.default

        let initial = folder.appendingPathComponent(fallback)
        if !manager.fileExists(atPath: initial.path) {
            return initial
        }

        var n = 2
        while n < 1000 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem) (\(n))"
            } else {
                candidateName = "\(stem) (\(n)).\(ext)"
            }
            let candidate = folder.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
        // Path-of-last-resort: a UUID suffix that's effectively guaranteed
        // to be unique. Avoids a 1000-iteration loop in pathological cases.
        let suffix = UUID().uuidString.prefix(8)
        let candidateName: String = ext.isEmpty
            ? "\(stem)-\(suffix)"
            : "\(stem)-\(suffix).\(ext)"
        return folder.appendingPathComponent(candidateName)
    }

    // MARK: - Internals

    private func reload() {
        let persisted = store.listDownloads()
        // Patch the in-memory progress on top of persisted rows for sessions
        // we still own. The store only sees a progress update every UI frame,
        // so live byte counters can be a hair fresher.
        var patched = persisted
        for index in patched.indices {
            if let session = sessions[patched[index].id] {
                patched[index].bytesReceived = session.bytesReceived
                if let total = session.bytesTotal {
                    patched[index].bytesTotal = total
                }
            }
        }
        records = patched
        recomputeAggregate()
    }

    private func updateInMemoryProgress(id: String, bytesReceived: Int64, bytesTotal: Int64?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].bytesReceived = bytesReceived
        if let bytesTotal { records[index].bytesTotal = bytesTotal }
        recomputeAggregate()
    }

    private func recomputeAggregate() {
        let active = records.filter { $0.state.isInFlight }
        activeCount = active.count
        guard !active.isEmpty else {
            aggregateProgress = 0
            return
        }
        var totalKnown: Int64 = 0
        var receivedKnown: Int64 = 0
        var indeterminate = 0
        for r in active {
            if let total = r.bytesTotal, total > 0 {
                totalKnown += total
                receivedKnown += min(r.bytesReceived, total)
            } else {
                indeterminate += 1
            }
        }
        if totalKnown > 0 {
            aggregateProgress = Double(receivedKnown) / Double(totalKnown)
        } else {
            aggregateProgress = 0
        }
        _ = indeterminate
    }
}

// MARK: - Per-download session (WK path)

/// One in-flight WK download. Owns the ``WKDownload``, its progress KVO
/// observation, and any retained resumeData. The controller keeps these in
/// a `[id: session]` map and routes user actions through this type.
@MainActor
final class DownloadSession: NSObject, AnyDownloadSession {
    let id: String
    fileprivate(set) var bytesReceived: Int64 = 0
    fileprivate(set) var bytesTotal: Int64?
    fileprivate var resumeData: Data?

    private weak var controller: DownloadController?
    private var download: WKDownload?
    private var progressObservation: NSKeyValueObservation?
    private var totalObservation: NSKeyValueObservation?
    private var paused = false

    enum CancelReason {
        case userCancelled
        case replaced
    }

    init(id: String, download: WKDownload, controller: DownloadController) {
        self.id = id
        self.download = download
        self.controller = controller
        super.init()
    }

    var canRetry: Bool { resumeData != nil }

    fileprivate func observe(_ download: WKDownload) {
        // WKDownload exposes its Progress via the `progress` property. We
        // KVO both `completedUnitCount` and `totalUnitCount` so the popover's
        // bar smoothly reflects byte counts.
        progressObservation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            Task { @MainActor in
                guard let self else { return }
                self.bytesReceived = received
                if let total { self.bytesTotal = total }
                self.controller?.sessionDidUpdateProgress(
                    id: self.id,
                    bytesReceived: received,
                    bytesTotal: total
                )
            }
        }
        totalObservation = download.progress.observe(\.totalUnitCount, options: [.new]) { [weak self] progress, _ in
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            Task { @MainActor in
                guard let self else { return }
                self.bytesTotal = total
                self.controller?.sessionDidUpdateProgress(
                    id: self.id,
                    bytesReceived: self.bytesReceived,
                    bytesTotal: total
                )
            }
        }
    }

    func cancel(reason: CancelReason) {
        guard let download else {
            controller?.sessionDidCancel(id: id)
            return
        }
        download.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                // Drop any partial file WK may have left behind on cancel.
                // The destination URL isn't directly recoverable from here,
                // so we rely on the controller's record lookup.
                if let record = self.controller?.records.first(where: { $0.id == self.id }),
                   !record.destinationPath.isEmpty {
                    try? FileManager.default.removeItem(atPath: record.destinationPath)
                }
                self.resumeData = data
                self.controller?.sessionDidCancel(id: self.id)
            }
        }
    }

    func pause() {
        guard let download, !paused else { return }
        paused = true
        download.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.resumeData = data
                self.controller?.sessionDidPause(id: self.id)
            }
        }
    }

    func resume() {
        guard paused, let resumeData else {
            controller?.sessionDidResume(id: id)
            return
        }
        paused = false
        restart(with: resumeData)
    }

    func retry() {
        guard let resumeData else { return }
        restart(with: resumeData)
    }

    /// Spins a fresh ``WKDownload`` off the retained resumeData. The bound
    /// `helper` ``WKWebView`` is only needed to host the call — once the
    /// new `WKDownload` is delegate-wired, it owns its own lifetime so the
    /// helper can fall out of scope.
    private func restart(with resumeData: Data) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let helper = WKWebView(frame: .zero, configuration: configuration)
        helper.resumeDownload(fromResumeData: resumeData) { [weak self] resumed in
            Task { @MainActor in
                guard let self else { return }
                self.resumeData = nil
                self.download = resumed
                resumed.delegate = self
                self.observe(resumed)
                self.controller?.sessionDidResume(id: self.id)
            }
        }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadSession: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload,
                              decideDestinationUsing response: URLResponse,
                              suggestedFilename: String,
                              completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        // The completionHandler is `@MainActor @Sendable` under Swift 6
        // strict concurrency. Hop to the main actor so we can call our
        // MainActor-isolated controller, then invoke it.
        let total: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            self.bytesTotal = total

            guard let destination = self.controller?.resolveDestination(suggestedFilename: suggestedFilename) else {
                completionHandler(nil)
                self.controller?.sessionDidCancel(id: self.id)
                return
            }
            // WK requires that the destination not already exist — our
            // ``uniqueDestination`` already enforces this, but the save
            // panel may target an existing file (user picked Replace).
            // Remove it first so the download can land.
            try? FileManager.default.removeItem(at: destination)
            self.controller?.sessionDidResolveDestination(id: self.id, destination: destination)
            self.observe(download)
            completionHandler(destination)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.progressObservation?.invalidate()
            self.totalObservation?.invalidate()
            self.controller?.sessionDidComplete(id: self.id, bytesReceived: self.bytesReceived)
        }
    }

    nonisolated func download(_ download: WKDownload,
                              didFailWithError error: Error,
                              resumeData: Data?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.progressObservation?.invalidate()
            self.totalObservation?.invalidate()
            self.resumeData = resumeData
            let nsError = error as NSError
            // NSURLErrorCancelled fires when *we* called .cancel() to
            // pause/cancel — in that case the user-initiated path has
            // already updated state, so don't overwrite with "failed".
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            self.controller?.sessionDidFail(
                id: self.id,
                message: nsError.localizedDescription,
                retryable: resumeData != nil
            )
        }
    }
}

// MARK: - URLSession fallback for retry-without-resumeData

/// Used only when a failed row has no resumeData (e.g. the failure happened
/// before bytes started flowing). Mirrors the same callback surface
/// ``DownloadSession`` uses.
@MainActor
final class URLSessionDownloadSession: NSObject, AnyDownloadSession {
    let id: String
    fileprivate(set) var bytesReceived: Int64 = 0
    fileprivate(set) var bytesTotal: Int64?
    fileprivate var resumeData: Data?

    private weak var controller: DownloadController?
    private let url: URL
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegateAdapter: URLSessionDelegateAdapter?

    init(id: String, url: URL, controller: DownloadController) {
        self.id = id
        self.url = url
        self.controller = controller
        super.init()
    }

    var canRetry: Bool { true }

    func start() {
        let suggested = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        guard let destination = controller?.resolveDestination(suggestedFilename: suggested) else {
            controller?.sessionDidCancel(id: id)
            return
        }
        controller?.sessionDidResolveDestination(id: id, destination: destination)

        let adapter = URLSessionDelegateAdapter(session: self, destination: destination)
        delegateAdapter = adapter
        let config = URLSessionConfiguration.default
        let urlSession = URLSession(configuration: config, delegate: adapter, delegateQueue: nil)
        self.session = urlSession
        let task = urlSession.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel(reason: DownloadSession.CancelReason) {
        task?.cancel()
        if let dest = delegateAdapter?.destination {
            try? FileManager.default.removeItem(at: dest)
        }
        controller?.sessionDidCancel(id: id)
    }

    func pause() {
        task?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.resumeData = data
                self.controller?.sessionDidPause(id: self.id)
            }
        })
    }

    func resume() {
        guard let resumeData, let session else { return }
        let task = session.downloadTask(withResumeData: resumeData)
        self.task = task
        self.resumeData = nil
        task.resume()
        controller?.sessionDidResume(id: id)
    }

    func retry() {
        // Fresh start — easiest when there's no resumeData.
        start()
    }

    fileprivate func report(received: Int64, total: Int64?) {
        bytesReceived = received
        if let total { bytesTotal = total }
        controller?.sessionDidUpdateProgress(id: id, bytesReceived: received, bytesTotal: total)
    }

    fileprivate func complete(received: Int64) {
        controller?.sessionDidComplete(id: id, bytesReceived: received)
    }

    fileprivate func fail(message: String, resumeData: Data?, retryable: Bool) {
        self.resumeData = resumeData
        controller?.sessionDidFail(id: id, message: message, retryable: retryable)
    }
}

/// `URLSessionDownloadDelegate` lives off the main actor by API contract;
/// this adapter bridges into the MainActor-isolated session via Tasks.
final class URLSessionDelegateAdapter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var session: URLSessionDownloadSession?
    let destination: URL

    init(session: URLSessionDownloadSession, destination: URL) {
        self.session = session
        self.destination = destination
        super.init()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { @MainActor [weak self] in
            self?.session?.report(received: totalBytesWritten, total: total)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            // The temp file at `location` is deleted after this method
            // returns; move it into place before we yield.
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            Task { @MainActor [weak self] in
                self?.session?.complete(received: size)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.session?.fail(message: error.localizedDescription, resumeData: nil, retryable: false)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak self] in
            self?.session?.fail(
                message: nsError.localizedDescription,
                resumeData: resumeData,
                retryable: resumeData != nil
            )
        }
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
