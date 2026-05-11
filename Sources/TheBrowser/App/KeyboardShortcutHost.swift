import AppKit
import SwiftUI

struct KeyboardShortcutHost: NSViewRepresentable {
    let bindings: [String: () -> Void]

    /// Normalizes the dictionary keys at construction time so that `command+
    /// shift+v` (a stored default) and `shift+command+v` (the form
    /// ``AppShortcut.storageValue(from:)`` produces from a real keypress)
    /// resolve to the same binding. Without this the lookup misses and the
    /// system handles the chord — for ⌘⇧V that means falling through to
    /// macOS's "Paste and Match Style".
    init(bindings: [String: () -> Void]) {
        var canonical: [String: () -> Void] = [:]
        canonical.reserveCapacity(bindings.count)
        for (raw, action) in bindings {
            canonical[AppShortcut.normalize(raw)] = action
        }
        self.bindings = canonical
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        var parent: KeyboardShortcutHost
        private var monitor: Any?

        init(parent: KeyboardShortcutHost) {
            self.parent = parent
        }

        func installMonitor() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let commandModifiers = event.modifierFlags.intersection([.command, .control, .option])
                guard !commandModifiers.isEmpty else {
                    return event
                }

                let shortcut = AppShortcut.storageValue(from: event)
                var handled = false

                MainActor.assumeIsolated {
                    guard let self, let shortcut else {
                        return
                    }

                    if let action = self.parent.bindings[shortcut] {
                        action()
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
