import AppKit
import SwiftUI

@main
struct TheBrowserApp: App {
    init() {
        AppDefaults.register()
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
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
                .frame(width: 620)
                .preferredColorScheme(.dark)
                .background(Palette.bg)
        }
    }
}
