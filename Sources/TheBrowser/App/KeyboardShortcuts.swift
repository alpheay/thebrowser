import AppKit
import SwiftUI

enum AppShortcut {
    static func displayString(for storageValue: String) -> String {
        let parts = storageValue.split(separator: "+").map(String.init)
        guard let key = parts.last else {
            return "None"
        }

        var display = ""
        if parts.contains("control") { display += "⌃" }
        if parts.contains("option") { display += "⌥" }
        if parts.contains("shift") { display += "⇧" }
        if parts.contains("command") { display += "⌘" }
        display += keyDisplayName(key)
        return display
    }

    static func storageValue(from event: NSEvent) -> String? {
        guard let key = normalizedKey(from: event), !key.isEmpty else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("command") }

        guard !parts.isEmpty else {
            return nil
        }

        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func matches(_ event: NSEvent, storageValue expectedValue: String) -> Bool {
        guard let recorded = storageValue(from: event) else { return false }
        return recorded == normalize(expectedValue)
    }

    /// Canonicalizes a stored shortcut string into the same form
    /// ``storageValue(from:)`` produces (`control+option+shift+command+key`).
    /// Keys that come back from `@AppStorage` aren't guaranteed to be in any
    /// particular order — the shortcut recorder happens to write canonical,
    /// but registered defaults and earlier user edits may not — so the
    /// keyboard host normalizes at lookup time and the dictionary keys it
    /// stores are normalized too. Dropping this normalization is what made
    /// `command+shift+v` (a stored default) miss against the event-derived
    /// `shift+command+v`.
    static func normalize(_ raw: String) -> String {
        let parts = raw.split(separator: "+").map(String.init)
        guard let key = parts.last else { return raw }
        let modifiers = Set(parts.dropLast())
        var ordered: [String] = []
        if modifiers.contains("control") { ordered.append("control") }
        if modifiers.contains("option") { ordered.append("option") }
        if modifiers.contains("shift") { ordered.append("shift") }
        if modifiers.contains("command") { ordered.append("command") }
        ordered.append(key)
        return ordered.joined(separator: "+")
    }

    private static func normalizedKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 36:
            return "return"
        case 48:
            return "tab"
        case 49:
            return "space"
        case 53:
            return "escape"
        case 123:
            return "left"
        case 124:
            return "right"
        case 125:
            return "down"
        case 126:
            return "up"
        default:
            return event.charactersIgnoringModifiers?.lowercased()
        }
    }

    private static func keyDisplayName(_ key: String) -> String {
        switch key {
        case "return":
            return "Return"
        case "tab":
            return "Tab"
        case "space":
            return "Space"
        case "escape":
            return "Esc"
        case "left":
            return "←"
        case "right":
            return "→"
        case "up":
            return "↑"
        case "down":
            return "↓"
        default:
            return key.uppercased()
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var value: String
    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "record.circle" : "keyboard")
                Text(isRecording ? "Press shortcut" : AppShortcut.displayString(for: value))
                    .monospacedDigit()
            }
            .frame(minWidth: 150, alignment: .center)
        }
        .buttonStyle(PillButtonStyle())
        .background {
            if isRecording {
                KeyCaptureView { shortcut in
                    value = shortcut
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
                .frame(width: 1, height: 1)
            }
        }
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    var onRecord: (String) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onRecord: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        if let shortcut = AppShortcut.storageValue(from: event) {
            onRecord?(shortcut)
        }
    }
}
