import SwiftUI

/// Compact dark-theme find-in-page overlay. Lives on the top-right of the
/// active webview and binds to a per-tab ``FindController``.
struct FindBarView: View {
    @ObservedObject var controller: FindController
    var onClose: () -> Void = {}

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)

            TextField("Find on page", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($fieldFocused)
                .frame(minWidth: 180, maxWidth: 240)
                .onSubmit { controller.next() }

            counterLabel

            Divider()
                .frame(height: 14)
                .overlay(Palette.stroke)
                .padding(.horizontal, 2)

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

    private var queryBinding: Binding<String> {
        Binding(
            get: { controller.query },
            set: { controller.updateQuery($0) }
        )
    }

    @ViewBuilder
    private var counterLabel: some View {
        if controller.query.isEmpty {
            EmptyView()
        } else if hasMatches {
            Text("\(controller.currentMatch)/\(controller.totalMatches)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textMuted)
                .monospacedDigit()
        } else {
            Text("No matches")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
    }
}
