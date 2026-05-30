import Combine
import Foundation
@preconcurrency import WebKit

/// App-wide coordinator for content blocking. Owns the user's preferences,
/// drives ``ContentRuleCompiler``, and publishes the compiled rule lists every
/// tab applies to its `WKWebView`. Singleton because — like the cited
/// clipboard — blocking is a cross-tab, app-lifetime concern; per-tab
/// `WKUserContentController`s call in through ``apply(to:)``.
///
/// The flow on any change:
/// preference edit → ``recompile()`` → compiler turns the enabled lists (plus
/// the allowlist) into `WKContentRuleList`s → the set is published and a
/// ``didChangeNotification`` fires → `BrowserModel` refreshes live tabs, while
/// freshly mounted tabs pick the set up in `mountWebViewStack`.
@MainActor
final class ContentBlockingController: ObservableObject {
    static let shared = ContentBlockingController()

    /// Broadcast after every compile settles (and when blocking is toggled
    /// off), so observers can re-apply the rule lists to already-live tabs
    /// without importing WebKit or knowing about `WKContentRuleList`.
    static let didChangeNotification = Notification.Name("ContentBlockingController.didChange")

    @Published private(set) var preferences: ContentBlockingPreferences
    /// Lists currently applied to web views. Empty while the first compile is
    /// in flight, or whenever blocking is disabled.
    @Published private(set) var compiledLists: [WKContentRuleList] = []
    @Published private(set) var isCompiling = false
    /// Total rules across the compiled lists — the honest stat we can surface.
    /// WebKit evaluates rules in its networking process and does not report
    /// per-request hits, so there is intentionally no "blocked today" counter.
    @Published private(set) var activeRuleCount = 0
    /// Names of enabled lists that failed to compile in the most recent pass.
    /// The browser still applies whatever did compile, but Settings surfaces
    /// this so the shield never implies full coverage after a partial failure.
    @Published private(set) var failedListNames: [String] = []

    /// Every available list, regardless of enabled state — drives the Settings
    /// category rows.
    let catalog: [BlockList]
    private let compiler: ContentRuleCompiler
    private let defaults: UserDefaults
    /// Bumped on each recompile request; a finished compile only publishes if
    /// its token still matches, so a rapid sequence of toggles can't apply a
    /// stale set of lists.
    private var compileGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        catalog: [BlockList] = BlockListCatalog.defaultLists(),
        compiler: ContentRuleCompiler = ContentRuleCompiler()
    ) {
        self.defaults = defaults
        self.catalog = catalog
        self.compiler = compiler
        self.preferences = ContentBlockingPreferences.load(from: defaults)
    }

    /// Kicks off the initial compile. Call once at launch (see
    /// ``TheBrowserApp``). Kept separate from `init` so tests can construct a
    /// controller without spinning up WebKit's compiler.
    func start() {
        recompile()
    }

    // MARK: - Preference reads

    var isEnabled: Bool { preferences.isEnabled }
    var allowedSites: [String] { preferences.allowList.sortedDomains }
    var isPopupBlockingEnabled: Bool { preferences.popupBlockingEnabled }
    var popupAllowedSites: [String] { preferences.popupAllowList.sortedDomains }

    func isEnabled(_ category: BlockListCategory) -> Bool {
        preferences.isEnabled(category)
    }

    func isAllowlisted(_ host: String) -> Bool {
        preferences.allowList.contains(host)
    }

    func isPopupAllowlisted(_ host: String) -> Bool {
        preferences.popupAllowList.contains(host)
    }

    // MARK: - Preference mutations

    func setEnabled(_ enabled: Bool) {
        guard preferences.isEnabled != enabled else { return }
        preferences.isEnabled = enabled
        persistAndRecompile()
    }

    func setCategory(_ category: BlockListCategory, enabled: Bool) {
        guard preferences.isEnabled(category) != enabled else { return }
        preferences.setCategory(category, enabled: enabled)
        persistAndRecompile()
    }

    func allow(_ hostOrURL: String) {
        let before = preferences.allowList
        preferences.allowList.insert(hostOrURL)
        guard preferences.allowList != before else { return }
        persistAndRecompile()
    }

    func removeAllow(_ host: String) {
        let before = preferences.allowList
        preferences.allowList.remove(host)
        guard preferences.allowList != before else { return }
        persistAndRecompile()
    }

    func setPopupBlockingEnabled(_ enabled: Bool) {
        guard preferences.popupBlockingEnabled != enabled else { return }
        preferences.popupBlockingEnabled = enabled
        persistOnly()
    }

    func allowPopups(_ hostOrURL: String) {
        let before = preferences.popupAllowList
        preferences.popupAllowList.insert(hostOrURL)
        guard preferences.popupAllowList != before else { return }
        persistOnly()
    }

    func removePopupAllow(_ host: String) {
        let before = preferences.popupAllowList
        preferences.popupAllowList.remove(host)
        guard preferences.popupAllowList != before else { return }
        persistOnly()
    }

    /// Per-site convenience: flip blocking for a page's host. Used by toolbar /
    /// shield affordances that act on the current tab.
    func toggleAllowlist(for url: URL) {
        guard let host = url.host else { return }
        if isAllowlisted(host) {
            removeAllow(host)
        } else {
            allow(host)
        }
    }

    // MARK: - Applying to web views

    /// Replaces whatever content rule lists are on `controller` with the
    /// current compiled set, or clears them when blocking is off. Idempotent —
    /// safe to call on every tab mount and on every change broadcast.
    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        guard preferences.isEnabled else { return }
        for list in compiledLists {
            controller.add(list)
        }
    }

    func shouldBlockPopup(
        openerURL: URL?,
        targetURL: URL?,
        navigationType: WKNavigationType
    ) -> Bool {
        let userActivated = navigationType == .linkActivated || navigationType == .formSubmitted
        return PopupBlockingPolicy.shouldBlock(
            isEnabled: preferences.popupBlockingEnabled,
            openerHost: openerURL?.host(percentEncoded: false),
            targetHost: targetURL?.host(percentEncoded: false),
            isUserActivated: userActivated,
            allowList: preferences.popupAllowList
        )
    }

    // MARK: - Compilation

    private func persistAndRecompile() {
        preferences.save(to: defaults)
        recompile()
    }

    private func persistOnly() {
        preferences.save(to: defaults)
    }

    private func recompile() {
        compileGeneration += 1
        let generation = compileGeneration

        guard preferences.isEnabled else {
            compiledLists = []
            activeRuleCount = 0
            failedListNames = []
            isCompiling = false
            broadcastChange()
            return
        }

        let lists = catalog.filter { preferences.isEnabled($0.category) }
        let allowlist = preferences.allowList.unlessDomainPatterns
        isCompiling = true
        failedListNames = []

        Task { @MainActor in
            var compiled: [WKContentRuleList] = []
            var ruleCount = 0
            var failures: [String] = []
            for list in lists {
                do {
                    compiled.append(try await compiler.compile(list, allowlistPatterns: allowlist))
                    ruleCount += list.ruleCount
                } catch {
                    // One bad list shouldn't sink the rest — skip it and keep
                    // whatever else compiles.
                    failures.append(list.name)
                    continue
                }
            }
            // A newer recompile superseded us — drop these stale results.
            guard generation == compileGeneration else { return }
            compiledLists = compiled
            activeRuleCount = ruleCount
            failedListNames = failures
            isCompiling = false
            broadcastChange()
        }
    }

    private func broadcastChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
