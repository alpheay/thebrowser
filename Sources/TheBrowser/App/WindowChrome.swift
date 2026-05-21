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

enum ThreadCommand {
    static let closeCurrentThread = Notification.Name("TheBrowser.closeCurrentThread")
}

@MainActor
final class ThreadWindowRegistry {
    static let shared = ThreadWindowRegistry()

    private final class WeakWindow {
        weak var window: NSWindow?

        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private var windows: [UUID: WeakWindow] = [:]

    func register(threadID: UUID, window: NSWindow) {
        windows[threadID] = WeakWindow(window)
    }

    func unregister(threadID: UUID, window: NSWindow?) {
        guard let current = windows[threadID]?.window else {
            windows[threadID] = nil
            return
        }

        if window == nil || current === window {
            windows[threadID] = nil
        }
    }

    func focus(threadID: UUID) -> Bool {
        guard let window = windows[threadID]?.window else {
            windows[threadID] = nil
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }
}

struct ThreadWindowCloseObserver: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void
    var onClose: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttach: onAttach, onClose: onClose)
    }

    func makeNSView(context: Context) -> ThreadWindowHookView {
        let view = ThreadWindowHookView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ThreadWindowHookView, context: Context) {
        context.coordinator.onAttach = onAttach
        context.coordinator.onClose = onClose
        nsView.coordinator = context.coordinator
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: ThreadWindowHookView, coordinator: Coordinator) {
        coordinator.removeObservers()
    }

    @MainActor
    final class Coordinator {
        var onAttach: (NSWindow) -> Void
        var onClose: (Bool) -> Void
        private weak var attachedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var terminateObserver: NSObjectProtocol?
        private var isTerminating = false

        init(
            onAttach: @escaping (NSWindow) -> Void,
            onClose: @escaping (Bool) -> Void
        ) {
            self.onAttach = onAttach
            self.onClose = onClose
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isTerminating = true
                }
            }
        }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            attachedWindow = window
            onAttach(window)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onClose(self.isTerminating)
                }
            }
        }

        func removeObservers() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            if let terminateObserver {
                NotificationCenter.default.removeObserver(terminateObserver)
            }
            closeObserver = nil
            terminateObserver = nil
        }
    }
}

final class ThreadWindowHookView: NSView {
    weak var coordinator: ThreadWindowCloseObserver.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            coordinator?.attach(to: window)
        }
    }
}
