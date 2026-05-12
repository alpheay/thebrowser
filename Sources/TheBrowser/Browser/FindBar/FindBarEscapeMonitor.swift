import AppKit
import SwiftUI

/// Closes the find bar on Esc regardless of where focus currently sits.
/// The find bar's own `onExitCommand` already covers the case where the
/// text field is focused, but users routinely click into the page after
/// finding a match and then expect Esc to dismiss the bar — same as
/// every other browser. ``KeyboardShortcutHost`` deliberately ignores
/// naked keystrokes, so the find bar's Esc lives in its own monitor.
struct FindBarEscapeMonitor: NSViewRepresentable {
    var isActive: Bool
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        var parent: FindBarEscapeMonitor
        private var monitor: Any?

        init(parent: FindBarEscapeMonitor) {
            self.parent = parent
        }

        func installIfNeeded() {
            if parent.isActive {
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // Escape
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, self.parent.isActive else { return }
                    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard mods.isEmpty else { return }
                    self.parent.onEscape()
                    handled = true
                }
                return handled ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
