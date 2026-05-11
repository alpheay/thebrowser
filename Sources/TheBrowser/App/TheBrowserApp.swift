import AppKit
import SwiftUI

@main
struct TheBrowserApp: App {
    init() {
        AppDefaults.register()
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            // Prime the cited-clipboard controller so its NSWorkspace
            // activation observer is installed before the user's first copy.
            _ = CitedClipboardController.shared
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

        Window("Discord", id: WindowID.discord) {
            DiscordClientView()
                .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 680)
                .preferredColorScheme(.dark)
                .background(Palette.bg)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 960, height: 680)
    }
}

enum WindowID {
    static let discord = "discord-client"
}
