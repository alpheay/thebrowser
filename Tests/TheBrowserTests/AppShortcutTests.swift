import Foundation
import Testing
@testable import TheBrowser

@Suite("AppShortcut")
struct AppShortcutTests {
    @Test("normalize reorders modifiers into canonical control+option+shift+command order")
    func normalizeReordersModifiers() {
        // The recorder produces this canonical order; defaults registered
        // in the wrong order used to silently miss the dictionary lookup.
        #expect(AppShortcut.normalize("command+shift+v") == "shift+command+v")
        #expect(AppShortcut.normalize("command+shift+r") == "shift+command+r")
        #expect(AppShortcut.normalize("option+command+x") == "option+command+x")
        #expect(AppShortcut.normalize("command+option+control+shift+a") == "control+option+shift+command+a")
    }

    @Test("normalize is idempotent on already-canonical strings")
    func normalizeIsIdempotent() {
        #expect(AppShortcut.normalize("shift+command+v") == "shift+command+v")
        #expect(AppShortcut.normalize("command+j") == "command+j")
    }

    @Test("normalize leaves single-modifier shortcuts untouched")
    func normalizeSingleModifier() {
        #expect(AppShortcut.normalize("command+t") == "command+t")
        #expect(AppShortcut.normalize("control+space") == "control+space")
    }
}
