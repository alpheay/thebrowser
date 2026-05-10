import AppKit
import SwiftUI
@preconcurrency import WebKit

struct KeyboardShortcutHost: NSViewRepresentable {
    var bindings: [String: () -> Void]

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

                guard !Self.isTypingTargetActive(for: event) else {
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

        private static func isTypingTargetActive(for event: NSEvent) -> Bool {
            guard let responder = event.window?.firstResponder else {
                return false
            }

            if responder is NSTextView {
                return true
            }

            var responderMirror: NSResponder? = responder
            while let current = responderMirror {
                if current is NSTextField || current is WKWebView {
                    return true
                }
                responderMirror = current.nextResponder
            }

            return false
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
