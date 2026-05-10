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
            guard attachedWindow !== window else {
                configureZoomButton(in: window)
                return
            }
            attachedWindow = window

            window.collectionBehavior.insert(.fullScreenPrimary)
            window.styleMask.insert(.resizable)
            configureZoomButton(in: window)

            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.configureZoomButton(in: window)
            }
        }

        private func configureZoomButton(in window: NSWindow) {
            guard let zoomButton = window.standardWindowButton(.zoomButton) else {
                return
            }

            zoomButton.isEnabled = true
            zoomButton.target = window
            zoomButton.action = #selector(NSWindow.toggleFullScreen(_:))
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
