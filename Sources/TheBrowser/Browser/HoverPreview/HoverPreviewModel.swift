import Foundation
import SwiftUI

/// Owns the floating hover preview panel: drives the fetcher + summarizer,
/// caches results, and produces a single ``PeekSession`` for the SwiftUI
/// layer to render. There is exactly one of these per ``BrowserShellView``
/// — the panel never appears on more than one tab simultaneously.
@MainActor
final class HoverPreviewModel: ObservableObject {
    /// One observable session that the panel binds to. Survives content
    /// swaps when the user hovers a different link without leaving the
    /// panel — only the inner phases flip.
    struct PeekSession: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var anchor: CGRect
        var tabID: BrowserTab.ID
        var content: ContentPhase
        var summary: SummaryPhase
        var fallbackTitle: String
    }

    enum ContentPhase: Equatable {
        case loading
        case ready(HoverPreviewContent)
        case authRequired
        case unavailable(reason: String)
    }

    enum SummaryPhase: Equatable {
        case idle
        case loading
        case ready(String)
        case failed
    }

    @Published private(set) var session: PeekSession?
    @Published private(set) var isPanelHovered = false

    let cache = HoverPreviewCache()
    private(set) lazy var prefetcher: HoverPreviewPrefetcher = HoverPreviewPrefetcher(cache: cache)

    private var fetchTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var pointerOnLink = false

    /// Surfaces the floating preview anchored to `anchor`. If we already
    /// have a session for the same URL on the same tab, only the anchor
    /// updates (the panel "tracks" the link as the page scrolls). If the
    /// URL is new but the panel is mounted, swap content in place so the
    /// panel doesn't tear down between hovers.
    func peek(url: URL, anchor: CGRect, tab: BrowserTab, fallbackTitle: String) {
        cancelDismiss()
        pointerOnLink = true

        if let existing = session, existing.tabID == tab.id, existing.url == url {
            session?.anchor = anchor
            return
        }

        let baseTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialContent: ContentPhase
        let initialSummary: SummaryPhase
        if let cached = cache.value(for: url) {
            initialContent = .ready(cached.content)
            initialSummary = cached.summary.map { .ready($0) } ?? .loading
        } else {
            initialContent = .loading
            initialSummary = .idle
        }

        session = PeekSession(
            url: url,
            anchor: anchor,
            tabID: tab.id,
            content: initialContent,
            summary: initialSummary,
            fallbackTitle: baseTitle
        )

        fetchTask?.cancel()
        summaryTask?.cancel()

        if case .ready(let content) = initialContent {
            if case .loading = initialSummary {
                kickSummary(for: url, content: content)
            }
            return
        }

        kickFetch(for: url)
    }

    /// Queue a prefetch — called for the JS `prefetch` message that fires
    /// after the no-modifier hover delay. Cheap when the URL is cached.
    func prefetch(url: URL) {
        prefetcher.prefetch(url)
    }

    /// JS signaled that the pointer left the link. We defer actually
    /// fading the panel for a short grace window so the user can move the
    /// cursor into the panel without losing it.
    func pointerLeftLink() {
        pointerOnLink = false
        scheduleDismissIfIdle()
    }

    /// SwiftUI reports whether the cursor is over the panel itself.
    /// Treated symmetrically to the link hover — either keeps the panel
    /// alive, both being false dismisses.
    func setPanelHovered(_ hovered: Bool) {
        isPanelHovered = hovered
        if hovered {
            cancelDismiss()
        } else {
            scheduleDismissIfIdle()
        }
    }

    /// The page scrolled or resized — JS sent a fresh rect for the link
    /// that's currently being previewed.
    func updateRect(_ rect: CGRect, for url: URL) {
        guard var current = session, current.url == url else { return }
        current.anchor = rect
        session = current
    }

    /// Hard dismiss (e.g. click outside, escape, settings disabled).
    func dismiss() {
        cancelDismiss()
        fetchTask?.cancel()
        summaryTask?.cancel()
        fetchTask = nil
        summaryTask = nil
        session = nil
        pointerOnLink = false
        isPanelHovered = false
    }

    // MARK: - Internal

    private func scheduleDismissIfIdle() {
        guard !pointerOnLink, !isPanelHovered else { return }
        cancelDismiss()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if !self.pointerOnLink, !self.isPanelHovered {
                withAnimation(.easeOut(duration: 0.14)) {
                    self.session = nil
                }
            }
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func kickFetch(for url: URL) {
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await HoverPreviewFetcher.fetch(url: url)
                guard !Task.isCancelled else { return }
                guard self.session?.url == url else { return }
                self.cache.setContent(content, for: url)
                self.session?.content = .ready(content)
                self.kickSummary(for: url, content: content)
            } catch HoverPreviewFetchError.authRequired {
                guard !Task.isCancelled else { return }
                guard self.session?.url == url else { return }
                self.session?.content = .authRequired
                self.session?.summary = .idle
            } catch HoverPreviewFetchError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard self.session?.url == url else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.session?.content = .unavailable(reason: message)
                self.session?.summary = .idle
            }
        }
    }

    private func kickSummary(for url: URL, content: HoverPreviewContent) {
        if let cached = cache.value(for: url)?.summary {
            session?.summary = .ready(cached)
            return
        }
        session?.summary = .loading
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await HoverPreviewSummarizer.summarize(content: content)
                guard !Task.isCancelled else { return }
                guard self.session?.url == url else { return }
                self.cache.setSummary(summary, for: url)
                self.session?.summary = .ready(summary)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard self.session?.url == url else { return }
                self.session?.summary = .failed
            }
        }
    }
}

/// One-line summarizer that piggybacks on the user's configured fast model.
/// Mirrors ``SmartReadClient.summarize`` but with a prompt scoped to "one
/// concrete sentence, no preamble, no markdown."
enum HoverPreviewSummarizer {
    static func summarize(content: HoverPreviewContent) async throws -> String {
        let configuration = AIHarnessConfiguration.current()
        let response = try await AIProviderClient().ask(
            prompt: prompt(content: content),
            systemPromptOverride: systemPrompt,
            modelOverride: configuration.provider.fastModelID
        )
        let trimmed = sanitize(response)
        guard !trimmed.isEmpty else { throw AIProviderError.emptyResponse }
        return trimmed
    }

    private static func prompt(content: HoverPreviewContent) -> String {
        let body = content.bodyText.isEmpty ? content.description : content.bodyText
        let trimmedBody = body.count > 4_000 ? String(body.prefix(4_000)) : body
        return """
        Write one concrete sentence (under 24 words) that tells a reader what this page is. Lead with the page's type or topic, name the subject explicitly, and avoid generic phrases like "This page discusses".

        Rules:
        - Plain prose, no markdown, no bullets, no quotation marks.
        - One sentence. No preamble like "This is" if the page is clearly an article — say what it's about directly.
        - Keep proper nouns and numbers; cut filler.

        Page:
        Title: \(content.title)
        URL: \(content.finalURL.absoluteString)
        Description: \(content.description)

        Body:
        \(trimmedBody)
        """
    }

    private static let systemPrompt = """
    You write extremely short, one-sentence link previews for a browser hover panel. Reply with just the sentence — no quotes, no markdown, no commentary.
    """

    private static func sanitize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip surrounding quotes if the model wraps the sentence.
        if trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
           ["\"", "'", "“", "”", "‘", "’"].contains(first),
           ["\"", "'", "“", "”", "‘", "’"].contains(last) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Take the first sentence/line — fast models sometimes overshoot.
        if let firstLine = trimmed.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) {
            trimmed = firstLine
        }
        return trimmed
    }
}
