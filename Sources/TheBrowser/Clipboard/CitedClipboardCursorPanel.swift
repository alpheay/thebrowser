import AppKit
import SwiftUI

/// Floating panel that hosts ``CitedClipboardPopover`` near the mouse cursor.
/// Used by the paste-with-citation keyboard shortcut so the menu is reachable
/// even when the toolbar button is hidden via the toolbar visibility settings.
@MainActor
final class CitedClipboardCursorPanelController {
    static let shared = CitedClipboardCursorPanelController()

    private var panel: KeyableBorderlessPanel?
    private var model: CitedClipboardPopoverModel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private static let panelSize = NSSize(width: 380, height: 460)

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            present(at: NSEvent.mouseLocation)
        }
    }

    func present(at screenPoint: NSPoint) {
        dismiss()

        let model = CitedClipboardPopoverModel()
        self.model = model

        let origin = computeOrigin(for: screenPoint, size: Self.panelSize)
        let panel = KeyableBorderlessPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let host = NSHostingView(
            rootView: CitedClipboardPopover(model: model) { [weak self] in
                Task { @MainActor in self?.dismiss() }
            }
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        )
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        self.panel = panel
        installDismissObservers(for: panel)

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func dismiss() {
        removeDismissObservers()
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Anchors the panel's top-left corner just below-right of the cursor and
    /// clamps it to the screen the cursor currently sits on so the panel never
    /// spills off-screen.
    private func computeOrigin(for cursor: NSPoint, size: NSSize) -> NSPoint {
        let preferredX = cursor.x + 4
        let preferredY = cursor.y - size.height - 4

        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 6

        let clampedX = min(max(visible.minX + margin, preferredX), visible.maxX - size.width - margin)
        let clampedY = min(max(visible.minY + margin, preferredY), visible.maxY - size.height - margin)
        return NSPoint(x: clampedX, y: clampedY)
    }

    private func installDismissObservers(for panel: NSPanel) {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if event.window === self?.panel { return event }
            Task { @MainActor in self?.dismiss() }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
                return nil
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func removeDismissObservers() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
        globalClickMonitor = nil
        localClickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
    }
}

/// Borderless `NSPanel` subclass that opts in to becoming key — required so
/// the embedded SwiftUI search field can receive keystrokes.
final class KeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
