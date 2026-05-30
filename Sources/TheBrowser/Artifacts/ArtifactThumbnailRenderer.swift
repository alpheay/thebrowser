import AppKit
import SwiftUI
import WebKit

/// Produces and caches preview images for artifacts. Each artifact is a
/// self-contained HTML document, so a thumbnail is rendered once by loading
/// it into an off-screen `WKWebView` and snapshotting the result, then cached
/// to disk forever (artifacts are immutable). Cards observe this object and
/// swap their glyph placeholder for the image as soon as it lands.
@MainActor
final class ArtifactThumbnailRenderer: ObservableObject {
    /// Decoded thumbnails keyed by artifact file name. Publishing the whole
    /// map is fine at gallery scale — a handful to a few dozen entries.
    @Published private(set) var images: [String: NSImage] = [:]

    /// At most this many off-screen web views render at once, to bound memory.
    private let maxConcurrent = 2
    private var inFlight = 0
    private var pending: [ArtifactMetadata] = []
    /// File names already imaged, in-flight, queued, or failed — so we never
    /// enqueue the same artifact twice (failed ones stay parked until relaunch).
    private var seen: Set<String> = []

    func thumbnail(for fileName: String) -> NSImage? {
        images[fileName]
    }

    /// Ensures a thumbnail exists for `artifact`: serves the in-memory or
    /// on-disk cache immediately, otherwise queues an off-screen render.
    /// Safe to call repeatedly (e.g. from each card's `onAppear`).
    func request(_ artifact: ArtifactMetadata) {
        let name = artifact.fileName
        if images[name] != nil || seen.contains(name) { return }

        // Disk cache hit — load and publish without rendering.
        let diskURL = ArtifactStore.thumbnailURL(forArtifactNamed: name)
        if let cached = NSImage(contentsOf: diskURL) {
            images[name] = cached
            seen.insert(name)
            return
        }

        seen.insert(name)
        pending.append(artifact)
        pump()
    }

    private func pump() {
        while inFlight < maxConcurrent, !pending.isEmpty {
            let artifact = pending.removeFirst()
            inFlight += 1
            Task { @MainActor in
                await self.render(artifact)
                self.inFlight -= 1
                self.pump()
            }
        }
    }

    private func render(_ artifact: ArtifactMetadata) async {
        let job = ArtifactSnapshotJob()
        let image = await job.run(url: artifact.url, readAccess: ArtifactStore.rootURL)
        job.teardown()
        guard let image else { return } // failed render keeps the glyph placeholder
        persist(image, forArtifactNamed: artifact.fileName)
        images[artifact.fileName] = image
    }

    private func persist(_ image: NSImage, forArtifactNamed fileName: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: ArtifactStore.thumbnailsRootURL,
            withIntermediateDirectories: true
        )
        try? png.write(to: ArtifactStore.thumbnailURL(forArtifactNamed: fileName), options: .atomic)
    }
}

/// One off-screen render: hosts a `WKWebView` in a hidden, far-off-screen
/// window (web content only paints when the view lives in a window), loads
/// the artifact, waits for the load to settle, and snapshots it.
@MainActor
private final class ArtifactSnapshotJob: NSObject, WKNavigationDelegate {
    /// Desktop-ish viewport so artifacts lay out as they would in a real tab.
    private let renderSize = NSSize(width: 1000, height: 750)
    /// Output thumbnail width in points; height follows the captured aspect.
    private let outputWidth: CGFloat = 600
    /// Grace period after `didFinish` so CDN fonts and Chart.js settle before
    /// the snapshot is taken.
    private let settle: TimeInterval = 0.6
    /// Hard cap so a hung load can't stall the render queue.
    private let timeout: TimeInterval = 12

    private let webView: WKWebView
    private let window: NSWindow
    private var continuation: CheckedContinuation<NSImage?, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(origin: .zero, size: renderSize), configuration: config)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: renderSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        // The window must sit on an actual display for WebKit to composite the
        // page — a fully off-screen window only renders its background colour,
        // which is why early snapshots came back as a flat black frame. So keep
        // it at the on-screen origin (0,0) but fully transparent and click-through,
        // which is invisible to the user yet still paints content.
        window.isOpaque = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func run(url: URL, readAccess: URL) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            self.continuation = cont
            window.orderFrontRegardless() // invisible (alpha 0, off-screen) but lets the view paint
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                self.finish(nil)
            }
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
    }

    func teardown() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(self.settle * 1_000_000_000))
            guard self.continuation != nil else { return }
            self.window.displayIfNeeded()
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: self.renderSize)
            config.snapshotWidth = NSNumber(value: Double(self.outputWidth))
            webView.takeSnapshot(with: config) { [weak self] image, _ in
                self?.finish(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    /// Resumes the continuation exactly once; later callers (timeout vs.
    /// snapshot vs. failure, whichever loses the race) are no-ops.
    private func finish(_ image: NSImage?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: image)
    }
}
