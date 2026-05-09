import SwiftUI

@main
struct TheBrowserApp: App {
    init() {
        AppDefaults.register()
    }

    var body: some Scene {
        WindowGroup {
            BrowserShellView()
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView()
                .frame(width: 620)
                .preferredColorScheme(.dark)
        }
    }
}
