import AppKit
import SwiftUI

struct KeyboardShortcutHost: NSViewRepresentable {
    var toggleChatShortcut: String
    var toggleTabsShortcut: String
    var onToggleChat: () -> Void
    var onToggleTabs: () -> Void

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
                let shortcut = AppShortcut.storageValue(from: event)
                var handled = false

                MainActor.assumeIsolated {
                    guard let self, let shortcut else {
                        return
                    }

                    if shortcut == self.parent.toggleChatShortcut {
                        self.parent.onToggleChat()
                        handled = true
                        return
                    }

                    if shortcut == self.parent.toggleTabsShortcut {
                        self.parent.onToggleTabs()
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
