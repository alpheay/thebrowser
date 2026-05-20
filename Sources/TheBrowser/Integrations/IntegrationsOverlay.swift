import AppKit
import SwiftUI

/// Floating overlay that hosts whichever integration view is active. Dim
/// backdrop, click-outside-to-close, Esc-to-close, centered card.
struct IntegrationsOverlay: View {
    @ObservedObject var model: IntegrationsModel
    @StateObject private var gmailAccount = GmailAccountStore.shared
    @StateObject private var gmailStore = GmailStore()

    var body: some View {
        ZStack {
            // Backdrop. Clicking it closes the overlay.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { model.close() }

            content
                .padding(.horizontal, 44)
                .padding(.vertical, 44)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

            // Naked-Esc handler — KeyboardShortcutHost ignores keystrokes
            // without modifiers.
            IntegrationsEscapeMonitor(isActive: model.isPresented) {
                model.close()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .animation(Motion.springSnap, value: model.isPresented)
        .onChange(of: model.activeIntegration) { _, _ in
            gmailAccount.reloadCredentials()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.activeIntegration ?? .gmail {
        case .gmail:
            GmailIntegrationView(
                store: gmailStore,
                account: gmailAccount,
                onClose: { model.close() }
            )
        }
    }
}

/// NSEvent monitor that picks up unmodified Escape key presses while the
/// overlay is on screen. Mirrors ``HistoryEscapeHandler`` — the shell-level
/// shortcut host only catches modified chords, so naked Esc needs its own
/// listener.
private struct IntegrationsEscapeMonitor: NSViewRepresentable {
    let isActive: Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(active: isActive)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.attach(active: isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attach(active: false)
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func attach(active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { // Escape
                        self?.onEscape()
                        return nil
                    }
                    return event
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
