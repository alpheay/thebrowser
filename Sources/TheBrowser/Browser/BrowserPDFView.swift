import AppKit
import Foundation
import PDFKit
import SwiftUI

/// SwiftUI wrapper that picks the right renderer for a tab's content:
/// PDFKit when the tab has loaded a PDF, WKWebView otherwise. Observes
/// the tab so the shell's `centerColumn` swaps in real time as soon as
/// ``BrowserTab/loadPDF(from:)`` finishes.
struct BrowserTabContent: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        if let error = tab.loadError {
            BrowserLoadErrorView(error: error) {
                tab.reload()
            }
        } else if let document = tab.pdfDocument {
            BrowserPDFView(tab: tab, document: document)
        } else {
            BrowserWebView(tab: tab)
        }
    }
}

private struct BrowserLoadErrorView: View {
    var error: BrowserLoadError
    var onRetry: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.94, green: 0.94, blue: 0.93)

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(red: 0.63, green: 0.15, blue: 0.12))

                VStack(spacing: 6) {
                    Text("Page Failed to Load")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.86))

                    Text(error.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    if let url = error.url?.absoluteString {
                        Text(url)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.44))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: 440)

                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 2)
            }
            .padding(32)
        }
    }
}

/// PDF tab content. WKWebView's built-in PDF viewer renders into a sandboxed
/// `<embed>` whose selection is invisible to ``TextSelectionBridge``'s JS
/// hook — so when a tab loads a PDF we swap in a PDFKit `PDFView` and
/// forward its native selection notifications back into ``BrowserTab``'s
/// `selectionInfo`. The shell-level ``TextSelectionOverlay`` then lights up
/// the same Ask/Summarize pill it shows over HTML pages.
struct BrowserPDFView: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.appearance = NSAppearance(named: .darkAqua)
        pdfView.backgroundColor = .black

        context.coordinator.pdfView = pdfView
        context.coordinator.attach()
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            tab.applySelectionInfo(nil)
        }
        context.coordinator.tab = tab
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var tab: BrowserTab

        init(tab: BrowserTab) {
            self.tab = tab
            super.init()
        }

        func attach() {
            guard let pdfView else { return }
            let nc = NotificationCenter.default
            nc.addObserver(self,
                           selector: #selector(selectionChanged),
                           name: .PDFViewSelectionChanged,
                           object: pdfView)
            nc.addObserver(self,
                           selector: #selector(viewportChanged),
                           name: .PDFViewScaleChanged,
                           object: pdfView)
            nc.addObserver(self,
                           selector: #selector(viewportChanged),
                           name: .PDFViewPageChanged,
                           object: pdfView)
            // PDFKit doesn't expose its inner scroll view publicly, so we
            // walk the subview tree once it's wired into the window to opt
            // it into bounds-changed notifications. Without this the pill
            // stays anchored to the original screen position when the user
            // scrolls the highlight away.
            DispatchQueue.main.async { [weak self] in
                self?.installScrollObserver()
            }
        }

        private func installScrollObserver() {
            guard let pdfView,
                  let scrollView = Self.findScrollView(in: pdfView) else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        private static func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            tab.applySelectionInfo(nil)
        }

        @objc private func selectionChanged(_ note: Notification) {
            emitSelection()
        }

        @objc private func viewportChanged(_ note: Notification) {
            emitSelection()
        }

        private func emitSelection() {
            guard let pdfView else { return }
            guard let selection = pdfView.currentSelection,
                  let raw = selection.string else {
                tab.applySelectionInfo(nil)
                return
            }
            let trimmed = raw
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                tab.applySelectionInfo(nil)
                return
            }

            // Union the per-page bounds projected into PDFView coordinates.
            // Selections that span pages get a single rect that covers all
            // of them; the floating widget anchors to that union.
            var union: CGRect? = nil
            for page in selection.pages {
                let pageBounds = selection.bounds(for: page)
                if pageBounds.isEmpty { continue }
                let viewRect = pdfView.convert(pageBounds, from: page)
                union = union.map { $0.union(viewRect) } ?? viewRect
            }
            guard let rect = union, !rect.isEmpty else {
                tab.applySelectionInfo(nil)
                return
            }

            // PDFView is a vanilla NSView (its `isFlipped` defaults to
            // false), so the converted rect uses bottom-left origin. Flip
            // into the SwiftUI overlay's top-left coordinate space — the
            // overlay sits exactly on top of the PDFView, so no further
            // conversion is needed.
            let display: CGRect
            if pdfView.isFlipped {
                display = rect
            } else {
                let h = pdfView.bounds.height
                display = CGRect(x: rect.origin.x,
                                 y: h - rect.origin.y - rect.height,
                                 width: rect.width,
                                 height: rect.height)
            }

            let truncated = trimmed.count > 12_000
                ? String(trimmed.prefix(12_000))
                : trimmed
            tab.applySelectionInfo(TextSelectionInfo(text: truncated, rect: display))
        }
    }
}
