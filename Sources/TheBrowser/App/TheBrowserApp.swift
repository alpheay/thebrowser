import AppKit
import SwiftUI

@main
struct TheBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppDefaults.register()
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            // Prime the cited-clipboard controller so its NSWorkspace
            // activation observer is installed before the user's first copy.
            _ = CitedClipboardController.shared
            // Prime the downloads controller too: it migrates any
            // "in-flight at last quit" rows into a failed state so the
            // popover doesn't show ghost downloads.
            _ = DownloadController.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserShellView()
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .background(Palette.bg)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView()
                .frame(minWidth: 900, idealWidth: 960, minHeight: 640, idealHeight: 720)
                .preferredColorScheme(.dark)
                .background(Palette.bg)
        }
    }
}

/// Lives only so we can run a few cleanup steps at quit time. Adding it via
/// `@NSApplicationDelegateAdaptor` is the lightest way to hook into
/// `applicationWillTerminate` from a SwiftUI app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DownloadController.shared.clearCompletedOnQuit()
    }
}
