import SwiftUI

/// Compact dark-theme find-in-page overlay. Lives on the top-right of the
/// active webview and binds to a per-tab ``FindController``.
///
/// The sparkle toggle flips between literal find and conversational find
/// ("where retry semantics are discussed"); both modes route through the
/// same WKWebView find pipeline, so highlighting and prev/next look
/// identical regardless of which mode resolved the needle.
struct FindBarView: View {
    @ObservedObject var controller: FindController
    var onClose: () -> Void = {}

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                modeIcon

                TextField(placeholder, text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .focused($fieldFocused)
                    .frame(minWidth: 200, maxWidth: 280)
                    .onSubmit { controller.submit() }

                statusLabel

                Divider()
                    .frame(height: 14)
                    .overlay(Palette.stroke)
                    .padding(.horizontal, 2)

                Button { controller.toggleAIMode() } label: {
                    Image(systemName: controller.isAIMode ? "sparkles" : "sparkle")
                }
                .buttonStyle(IconButtonStyle(selected: controller.isAIMode, size: 22))
                .help(controller.isAIMode
                      ? "Switch to literal find"
                      : "Switch to conversational find")

                Button { controller.previous() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .disabled(!hasMatches)
                .opacity(hasMatches ? 1 : 0.4)
                .help("Previous match (\u{21E7}\u{2318}G)")

                Button { controller.next() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .disabled(!hasMatches)
                .opacity(hasMatches ? 1 : 0.4)
                .help("Next match (\u{2318}G)")

                Button {
                    controller.hide()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Close (Esc)")
            }

            aiCaption
                .padding(.leading, 18)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 10)
        .onAppear { fieldFocused = true }
        .onChange(of: controller.focusRequestToken) { _, _ in
            fieldFocused = true
            // Re-focusing an already-visible field is a no-op for
            // @FocusState, so when ⌘F fires twice in a row we also push
            // the field to select its existing text — same behavior as
            // every other browser's address bar.
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onExitCommand {
            controller.hide()
            onClose()
        }
    }

    private var hasMatches: Bool { controller.totalMatches > 0 }

    private var placeholder: String {
        controller.isAIMode ? "Ask about this page\u{2026}" : "Find on page"
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { controller.query },
            set: { controller.updateQuery($0) }
        )
    }

    @ViewBuilder
    private var modeIcon: some View {
        if controller.isAIMode {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if controller.aiSearching {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        } else if controller.query.isEmpty {
            EmptyView()
        } else if hasMatches {
            Text("\(controller.currentMatch)/\(controller.totalMatches)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textMuted)
                .monospacedDigit()
        } else if controller.isAIMode, controller.aiResolvedPhrase == nil, controller.aiError == nil {
            Text("\u{21B5} to search")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        } else {
            Text("No matches")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
    }

    /// Second-line caption that surfaces the AI-resolved phrase or error.
    /// Collapses to nothing in literal mode, which keeps the bar single-row
    /// and the same height as the previous find bar.
    @ViewBuilder
    private var aiCaption: some View {
        if controller.isAIMode, let phrase = controller.aiResolvedPhrase, !phrase.isEmpty {
            HStack(spacing: 4) {
                Text("Showing:")
                    .foregroundStyle(Palette.textFaint)
                Text("\u{201C}\(phrase)\u{201D}")
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10.5, weight: .medium))
        } else if controller.isAIMode, let error = controller.aiError {
            Text(error)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)
                .lineLimit(2)
        } else {
            EmptyView()
        }
    }
}
