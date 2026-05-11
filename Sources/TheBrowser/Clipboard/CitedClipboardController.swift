import AppKit
import Foundation
import UniformTypeIdentifiers

/// Per-app citation rule. The pasteboard rewriter uses these to choose how
/// to format the plain-text rep when the destination app activates.
struct CitedAppRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Markdown-friendly editors. The plain-text rep gets rewritten to
        /// the user's selected markdown style on app activation.
        case markdown
        /// Rich-text apps that paste HTML happily. Plain-text rep is left
        /// alone — the augmented `public.html` rep already carries the
        /// citation footer.
        case richText
        /// Default behavior — never rewrite anything.
        case plain
    }

    var bundleID: String
    var displayName: String
    var kind: Kind

    var id: String { bundleID }
}

/// Coordinator for the cited clipboard. Owns:
///
/// - The capture pipeline: turns a JS copy event into a `CitedClip` plus
///   pasteboard writes (plain text, augmented HTML, custom JSON UTI).
/// - The smart-paste rewriter: an NSWorkspace observer that, when a known
///   markdown app activates, rewrites the plain-text rep so paste lands
///   already-formatted.
///
/// Singleton because pasteboard ownership and app-activation observation
/// are app-wide concerns; `CitedClipboardBridge` instances per tab call
/// into it.
@MainActor
final class CitedClipboardController {
    static let shared = CitedClipboardController()

    /// UTI string for our custom JSON rep. WebKit maps the `text/plain` and
    /// `text/html` types from JS `setData` to standard NSPasteboard types;
    /// the custom MIME shows up here unchanged.
    static let customPasteboardType = NSPasteboard.PasteboardType("com.thebrowser.cited")

    /// Default per-app rules. Bundle IDs taken from each app's Info.plist.
    static let defaultAppRules: [CitedAppRule] = [
        // Markdown destinations.
        CitedAppRule(bundleID: "md.obsidian", displayName: "Obsidian", kind: .markdown),
        CitedAppRule(bundleID: "pro.writer.mac", displayName: "iA Writer", kind: .markdown),
        CitedAppRule(bundleID: "net.shinyfrog.bear", displayName: "Bear", kind: .markdown),
        CitedAppRule(bundleID: "notion.id", displayName: "Notion", kind: .markdown),
        CitedAppRule(bundleID: "com.electron.logseq", displayName: "Logseq", kind: .markdown),
        CitedAppRule(bundleID: "abnerworks.Typora", displayName: "Typora", kind: .markdown),
        // Rich-text destinations.
        CitedAppRule(bundleID: "com.apple.Notes", displayName: "Notes", kind: .richText),
        CitedAppRule(bundleID: "com.apple.mail", displayName: "Mail", kind: .richText),
        CitedAppRule(bundleID: "com.apple.iWork.Pages", displayName: "Pages", kind: .richText),
        CitedAppRule(bundleID: "com.apple.TextEdit", displayName: "TextEdit", kind: .richText)
    ]

    /// The store backs the in-app clipboard history. Tests can inject a
    /// custom store via the initializer.
    let store: CitedClipboardStore

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let workspace: NSWorkspace

    /// Pasteboard `changeCount` we recorded after our last write. Used for
    /// ownership tracking — if it advances without us, the user copied
    /// something else and we stop touching it.
    private var ownedChangeCount: Int = -1
    /// The clip we most recently wrote — what the rewriter formats from
    /// when an app activates while we still own the pasteboard.
    private var ownedClip: CitedClip?
    /// True after a manual paste-with-citation write, so the rewriter
    /// doesn't second-guess the user's explicit format pick.
    private var ownershipIsManual = false

    /// `nonisolated(unsafe)` so the nonisolated deinit can hand the token
    /// back to NSWorkspace's notification center. In practice the
    /// controller is the app-lifetime singleton, so deinit never fires —
    /// the marking exists to keep tests + future refactors honest.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init(
        store: CitedClipboardStore = CitedClipboardStore.shared,
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        workspace: NSWorkspace = .shared
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.workspace = workspace
        installActivationObserver()
    }

    deinit {
        if let activationObserver {
            // NSWorkspace observers go through its own notification center,
            // not the default one — must remove from the same source.
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Capture pipeline

    /// Called by ``CitedClipboardBridge`` after a JS copy event. Decides
    /// whether to enrich + persist, then takes pasteboard ownership so the
    /// rewriter can do its job on the next app activation.
    func recordCopy(
        text: String,
        html: String,
        sentenceBefore: String,
        sentenceAfter: String,
        tab: BrowserTab
    ) {
        guard isEnabled else { return }
        guard tab.allowsClipboardCapture else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let host = tab.url?.host(percentEncoded: false) ?? ""
        if CitedClipboardPolicy.isBlocked(host: host, defaults: defaults) {
            // Blocked: don't persist or take ownership. The browser's default
            // copy already wrote plain text + HTML; we just step back.
            return
        }

        let clip = CitedClip(
            text: trimmed,
            sourceURL: tab.url?.absoluteString ?? "",
            sourceTitle: tab.title,
            pageDomain: host,
            timestamp: Date(),
            sentenceBefore: sentenceBefore,
            sentenceAfter: sentenceAfter,
            copiedFromTabTitle: tab.displayTitle
        )

        store.insert(clip)
        ownClip(clip, manual: false)
    }

    /// Writes a clip to the pasteboard in the user's chosen format. Used by
    /// the ⌘⇧V popover — flagged as "manual" so the smart-paste rewriter
    /// won't override the explicit pick on app activation.
    func paste(clip: CitedClip, format: CitedClipFormat) {
        let rendered = CitedClipFormatter.render(clip, as: format)
        pasteboard.clearContents()
        pasteboard.setString(rendered, forType: .string)
        writeCustomCitedRep(for: clip)
        ownedChangeCount = pasteboard.changeCount
        ownedClip = clip
        ownershipIsManual = true
    }

    /// Re-puts a clip on the pasteboard exactly as captured (no formatting).
    /// Used by the "Re-copy" affordances in Settings + the popover.
    func recopy(clip: CitedClip) {
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        writeCustomCitedRep(for: clip)
        ownedChangeCount = pasteboard.changeCount
        ownedClip = clip
        ownershipIsManual = false
    }

    // MARK: - Smart paste rewriter

    private func installActivationObserver() {
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // The closure is delivered on the queue we passed, but the type
            // checker still needs reassurance for MainActor isolation.
            MainActor.assumeIsolated {
                self?.handleActivation(of: app)
            }
        }
    }

    private func handleActivation(of app: NSRunningApplication) {
        guard isEnabled, isSmartPasteEnabled else { return }
        guard let bundleID = app.bundleIdentifier else { return }
        // Activations of TheBrowser itself never rewrite the clipboard —
        // we don't want to mutate our own pasteboard while the user is
        // still inside the popover.
        if bundleID == Bundle.main.bundleIdentifier { return }
        guard pasteboard.changeCount == ownedChangeCount, let clip = ownedClip else { return }
        if ownershipIsManual { return }
        guard let rule = rule(for: bundleID), rule.kind == .markdown else { return }

        let format = currentMarkdownStyle.pasteFormat
        let rendered = CitedClipFormatter.render(clip, as: format)
        // Re-clear and re-write so we own the changeCount cleanly. The
        // custom JSON rep is preserved for any downstream consumer that
        // wants the structured payload.
        pasteboard.clearContents()
        pasteboard.setString(rendered, forType: .string)
        writeCustomCitedRep(for: clip)
        ownedChangeCount = pasteboard.changeCount
    }

    // MARK: - Ownership / pasteboard writes

    private func ownClip(_ clip: CitedClip, manual: Bool) {
        // The browser's default copy has already written `text/plain` and
        // `text/html` for us — we layer on the custom JSON rep + record
        // ownership so the rewriter can take over from here.
        writeCustomCitedRep(for: clip)
        ownedChangeCount = pasteboard.changeCount
        ownedClip = clip
        ownershipIsManual = manual
    }

    private func writeCustomCitedRep(for clip: CitedClip) {
        guard let data = try? JSONEncoder().encode(CitedClipPayload(clip: clip)) else { return }
        // Adding a type to the existing pasteboard contents instead of
        // clearing — keeps the WebKit-written `text/plain` + `text/html`
        // reps intact when we're enriching after the default copy.
        pasteboard.addTypes([Self.customPasteboardType], owner: nil)
        pasteboard.setData(data, forType: Self.customPasteboardType)
    }

    // MARK: - Settings accessors

    private var isEnabled: Bool {
        defaults.object(forKey: PreferenceKey.clipboardEnabled) as? Bool ?? true
    }

    private var isSmartPasteEnabled: Bool {
        defaults.object(forKey: PreferenceKey.clipboardSmartPasteEnabled) as? Bool ?? true
    }

    private var currentMarkdownStyle: CitedMarkdownStyle {
        let raw = defaults.string(forKey: PreferenceKey.clipboardMarkdownStyle) ?? CitedMarkdownStyle.blockquote.rawValue
        return CitedMarkdownStyle(rawValue: raw) ?? .blockquote
    }

    /// Looks up the per-app rule for `bundleID`, merging the user's overrides
    /// with the default list (overrides win on conflict).
    private func rule(for bundleID: String) -> CitedAppRule? {
        let overrides = decodedAppRuleOverrides()
        if let override = overrides.first(where: { $0.bundleID == bundleID }) {
            return override
        }
        return Self.defaultAppRules.first(where: { $0.bundleID == bundleID })
    }

    private func decodedAppRuleOverrides() -> [CitedAppRule] {
        guard let raw = defaults.string(forKey: PreferenceKey.clipboardAppOverrides),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CitedAppRule].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Wire format for the custom JSON pasteboard rep. Mirrors the spec's
/// `com.thebrowser.cited` payload shape.
private struct CitedClipPayload: Encodable {
    var text: String
    var sourceUrl: String
    var sourceTitle: String
    var pageDomain: String
    var timestamp: String
    var sentenceBefore: String
    var sentenceAfter: String
    var copiedFromTabTitle: String

    init(clip: CitedClip) {
        self.text = clip.text
        self.sourceUrl = clip.sourceURL
        self.sourceTitle = clip.sourceTitle
        self.pageDomain = clip.pageDomain
        self.timestamp = ISO8601DateFormatter().string(from: clip.timestamp)
        self.sentenceBefore = clip.sentenceBefore
        self.sentenceAfter = clip.sentenceAfter
        self.copiedFromTabTitle = clip.copiedFromTabTitle
    }
}
