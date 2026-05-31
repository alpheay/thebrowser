import AppKit
import SwiftUI

/// Floating overlay that hosts whichever integration view is active. Dim
/// backdrop, click-outside-to-close, Esc-to-close, centered card.
struct IntegrationsOverlay: View {
    @ObservedObject var model: IntegrationsModel
    @ObservedObject var gmailAccount: GmailAccountStore
    @ObservedObject var gmailStore: GmailStore
    @ObservedObject var mailModel: MailModel
    /// Width reserved on the right (the AI chat dock) so the inbox sits beside
    /// the chat instead of covering it — the chat stays visible and clickable.
    var rightInset: CGFloat = 0

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ZStack {
                    // Backdrop. Clicking it closes the overlay. It only dims the
                    // inbox region, never the chat dock.
                    Color.black.opacity(0.45)
                        .onTapGesture { model.close() }

                    content
                        .padding(.horizontal, 30)
                        .padding(.vertical, 36)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if rightInset > 0 {
                    // Transparent, click-through gap so the chat panel below
                    // stays visible and interactive while mail is open.
                    Color.clear
                        .frame(width: rightInset)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()

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
        .animation(Motion.springSnap, value: rightInset)
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
                mailModel: mailModel,
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
