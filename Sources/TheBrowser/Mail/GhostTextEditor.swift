import AppKit
import SwiftUI

/// A plain-text editor with inline "ghost text" autocomplete, à la Slashy.
///
/// The SwiftUI `TextEditor` can't render an inline suggestion, so this wraps an
/// `NSTextView`. The *real* text always lives in the `text` binding; a
/// suggestion is shown as a throwaway, dimmed run appended after the cursor and
/// is only committed to the binding when the user accepts it (Tab). Any edit
/// removes the ghost first, so the binding never contains un-accepted text.
///
/// Requests are **throttled** (at most one per `throttle` seconds while typing),
/// any in-flight request is dropped if the text changes, and ⌘\ forces an
/// immediate suggestion. This keeps the small model from being spammed.
struct GhostTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var throttle: TimeInterval
    var font: NSFont = .systemFont(ofSize: 13)
    /// Given the draft text up to the cursor, return a short continuation.
    var onRequestCompletion: @MainActor (String) async -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = GhostTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = NSColor.white
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        context.coordinator.textView = textView
        context.coordinator.realText = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isEnabled = isEnabled
        guard let textView = nsView.documentView as? GhostTextView else { return }
        if textView.font != font { textView.font = font }
        // External replacement (e.g. an AI edit rewrote the body).
        if context.coordinator.realText != text {
            context.coordinator.clearSuggestion()
            if textView.string != text { textView.string = text }
            context.coordinator.realText = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GhostTextEditor
        var isEnabled: Bool
        weak var textView: GhostTextView?
        var realText: String = ""

        private var suggestionRange: NSRange?
        private var pending: Task<Void, Never>?
        private var lastRequest: Date = .distantPast

        init(_ parent: GhostTextEditor) {
            self.parent = parent
            self.isEnabled = parent.isEnabled
        }

        var hasSuggestion: Bool { suggestionRange != nil }

        // MARK: Delegate

        /// Fires before any edit (typing, delete, paste). Removing the ghost
        /// here means it never lingers in the wrong place and the binding never
        /// sees un-accepted text.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            clearSuggestion()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            realText = textView.string
            parent.text = realText
            scheduleCompletion()
        }

        // MARK: Suggestion lifecycle

        func showSuggestion(_ suggestion: String) {
            guard let textView, let storage = textView.textStorage, suggestionRange == nil else { return }
            let end = (textView.string as NSString).length
            guard textView.selectedRange().location == end, textView.selectedRange().length == 0 else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.30),
                .font: textView.font ?? parent.font
            ]
            storage.insert(NSAttributedString(string: suggestion, attributes: attributes), at: end)
            suggestionRange = NSRange(location: end, length: (suggestion as NSString).length)
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        func clearSuggestion() {
            defer { suggestionRange = nil }
            guard let textView, let storage = textView.textStorage, let range = suggestionRange else { return }
            guard NSMaxRange(range) <= storage.length else { return }
            storage.deleteCharacters(in: range)
        }

        func acceptSuggestion() {
            guard let textView, let storage = textView.textStorage, let range = suggestionRange else { return }
            storage.removeAttribute(.foregroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.92), range: range)
            suggestionRange = nil
            textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            realText = textView.string
            parent.text = realText
        }

        // MARK: Completion requests

        func scheduleCompletion() {
            pending?.cancel()
            guard isEnabled else { return }
            let delay = max(0, parent.throttle - Date().timeIntervalSince(lastRequest))
            pending = Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if Task.isCancelled { return }
                await self?.fireCompletion()
            }
        }

        func forceCompletion() {
            pending?.cancel()
            lastRequest = .distantPast
            pending = Task { @MainActor [weak self] in await self?.fireCompletion() }
        }

        private func fireCompletion() async {
            guard let textView, isEnabled, suggestionRange == nil else { return }
            let end = (textView.string as NSString).length
            guard textView.selectedRange().location == end, textView.selectedRange().length == 0 else { return }
            let prefix = textView.string
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
            lastRequest = Date()
            guard let suggestion = await parent.onRequestCompletion(prefix),
                  !suggestion.isEmpty else { return }
            // Drop if the user typed while we were waiting.
            guard textView.string == prefix, suggestionRange == nil else { return }
            showSuggestion(suggestion)
        }
    }
}

/// NSTextView that routes edits through the coordinator so the ghost run is
/// removed before any change, Tab accepts it, Esc dismisses it, and ⌘\ forces
/// a fresh suggestion.
final class GhostTextView: NSTextView {
    weak var coordinator: GhostTextEditor.Coordinator?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertTab(_:)), coordinator?.hasSuggestion == true {
            coordinator?.acceptSuggestion()
            return
        }
        if selector == #selector(cancelOperation(_:)), coordinator?.hasSuggestion == true {
            coordinator?.clearSuggestion()
            return
        }
        // Cursor-moving / non-text commands (arrows, etc.) drop the ghost so it
        // never lingers in the wrong place. Text-changing commands are handled
        // by shouldChangeTextIn.
        coordinator?.clearSuggestion()
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "\\" {
            coordinator?.forceCompletion()
            return
        }
        super.keyDown(with: event)
    }
}
