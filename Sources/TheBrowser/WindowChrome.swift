import AppKit
import SwiftUI

/// Reroutes the green traffic-light (zoom) button so a click enters native
/// macOS full-screen mode instead of doing a desktop "maximize."
struct WindowFullScreenZoomConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowHookView, context: Context) {
        nsView.coordinator = context.coordinator
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var attachedWindow: NSWindow?

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            attachedWindow = window

            window.collectionBehavior.insert(.fullScreenPrimary)

            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.target = self
                zoomButton.action = #selector(handleZoomClick(_:))
            }
        }

        @objc func handleZoomClick(_ sender: NSButton) {
            // Option-click preserves traditional zoom-to-fit behavior
            if NSEvent.modifierFlags.contains(.option) {
                sender.window?.performZoom(nil)
            } else {
                sender.window?.toggleFullScreen(nil)
            }
        }
    }
}

/// Bridges SwiftUI's view tree to the underlying NSWindow. Notifies its
/// coordinator the moment AppKit attaches it to a window.
final class WindowHookView: NSView {
    weak var coordinator: WindowFullScreenZoomConfigurator.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            coordinator?.attach(to: window)
        }
    }
}
