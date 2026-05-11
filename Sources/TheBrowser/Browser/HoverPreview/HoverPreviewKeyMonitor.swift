import AppKit
import SwiftUI

/// Tiny `NSEvent` local-monitor host that intercepts Return and ⌘Return
/// only while a hover preview session is visible. We need this because
/// ``KeyboardShortcutHost`` deliberately ignores naked keystrokes (it
/// only fires when at least one of ⌃/⌥/⌘ is held).
struct HoverPreviewKeyMonitor: NSViewRepresentable {
    var sessionVisible: Bool
    var onReturn: () -> Void
    var onCommandReturn: () -> Void

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
        var parent: HoverPreviewKeyMonitor
        private var monitor: Any?

        init(parent: HoverPreviewKeyMonitor) {
            self.parent = parent
        }

        func installIfNeeded() {
            if parent.sessionVisible {
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 36 else { return event } // Return
                var handled = false
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.parent.sessionVisible else { return }
                    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if mods == [] {
                        self.parent.onReturn()
                        handled = true
                    } else if mods == .command {
                        self.parent.onCommandReturn()
                        handled = true
                    }
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
