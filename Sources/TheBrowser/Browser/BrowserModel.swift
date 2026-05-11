import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var selectedTabID: BrowserTab.ID
    @Published var isTabRailVisible = true
    @Published var isChatVisible = true
    @Published var addressDraft = ""
    @Published var addressFocusToken = 0
    @Published var webControlStatus: WebControlStatus?

    /// Cadence (seconds) at which the background sweep walks the tab list
    /// and hibernates anything past the idle threshold. Sixty seconds is
    /// short enough that a 30-minute setting feels exact and long enough
    /// that the sweep itself is invisible.
    private static let hibernationSweepInterval: UInt64 = 60_000_000_000
    private var hibernationSweepTask: Task<Void, Never>?

    init() {
        let firstTab = BrowserTab()
        tabs = [firstTab]
        selectedTabID = firstTab.id
        startHibernationSweep()
    }

    deinit {
        hibernationSweepTask?.cancel()
    }

    var selectedTab: BrowserTab {
        if let selected = tabs.first(where: { $0.id == selectedTabID }) {
            return selected
        }

        return tabs[0]
    }

    var selectedContext: BrowserPageContext {
        BrowserPageContext(title: selectedTab.displayTitle, url: selectedTab.displayAddress)
    }

    func select(_ tab: BrowserTab) {
        // Stamp the outgoing tab's last-active timestamp so the idle
        // window starts now, not the moment it was first opened.
        if let outgoing = tabs.first(where: { $0.id == selectedTabID }), outgoing.id != tab.id {
            outgoing.lastActiveAt = Date()
        }
        selectedTabID = tab.id
        tab.lastActiveAt = Date()
        if tab.isHibernated {
            // `webView` is a lazy property — touching it rebuilds the
            // stack and reloads the URL. We don't keep a reference; the
            // BrowserTabContent that SwiftUI re-creates after this state
            // change will fetch the fresh view.
            _ = tab.webView
        }
        addressDraft = tab.displayAddress
    }

    func addTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        select(tab)
    }

    /// Opens `url` in a freshly created tab. The new tab is appended to the
    /// list (pinned tabs always lead in the rail via ``TabRailView``'s sort).
    /// Set `background` to keep the current tab selected. Set `pinned` to
    /// mark the new tab as pinned — used by Hover Preview's "Pin" footer.
    func openInNewTab(url: URL, background: Bool = false, pinned: Bool = false) {
        let tab = BrowserTab()
        tab.isPinned = pinned
        tabs.append(tab)
        if !background {
            select(tab)
        }
        tab.navigate(to: url.absoluteString)
        if !background {
            updateAddressFromSelectedTab()
        }
    }

    func close(_ tab: BrowserTab) {
        guard tabs.count > 1 else {
            tab.goHome()
            addressDraft = ""
            return
        }

        let wasSelected = tab.id == selectedTabID
        tabs.removeAll { $0.id == tab.id }

        if wasSelected {
            select(tabs[max(0, tabs.count - 1)])
        }
    }

    func closeSelected() {
        close(selectedTab)
    }

    func navigateSelected(to input: String? = nil) {
        let target = input ?? addressDraft
        selectedTab.navigate(to: target)
        addressDraft = selectedTab.displayAddress
    }

    func goHome() {
        selectedTab.goHome()
        addressDraft = ""
    }

    func updateAddressFromSelectedTab() {
        addressDraft = selectedTab.displayAddress
    }

    func toggleTabs() {
        isTabRailVisible.toggle()
    }

    func toggleChat() {
        isChatVisible.toggle()
    }

    func focusAddress() {
        addressFocusToken &+= 1
    }

    /// Snapshot of the currently open tabs, formatted for the AI prompt's
    /// "Open tabs:" block. 1-based indexing so the model can refer to tabs
    /// by the same numbers the user sees.
    func tabsManifest() -> [TabManifestEntry] {
        tabs.enumerated().map { offset, tab in
            let isContent = !tab.isHome && tab.searchPage == nil
            let address: String
            if tab.isHome {
                address = "(home)"
            } else if let search = tab.searchPage {
                address = "search: \(search.query)"
            } else {
                address = tab.displayAddress
            }
            return TabManifestEntry(
                index: offset + 1,
                title: tab.displayTitle,
                url: address,
                isSelected: tab.id == selectedTabID,
                isContent: isContent
            )
        }
    }

    /// Returns formatted text content of the requested tabs (1-based indices),
    /// or all content tabs when `indices` is nil. Skips home/search tabs.
    /// Used by the AI chat's `read_tabs` tool.
    func collectTabsContent(indices: [Int]?) async -> String {
        let allTabs = tabs
        let total = allTabs.count
        let selected: [(Int, BrowserTab)]
        if let indices, !indices.isEmpty {
            selected = indices.compactMap { index in
                guard index >= 1, index <= total else { return nil }
                return (index, allTabs[index - 1])
            }
        } else {
            selected = allTabs.enumerated().map { ($0.offset + 1, $0.element) }
        }

        var sections: [String] = []
        for (index, tab) in selected {
            let header = "Tab \(index): \(tab.displayTitle)\nURL: \(tab.displayAddress.isEmpty ? "(home)" : tab.displayAddress)"
            if tab.isHome {
                sections.append("\(header)\n\n[Home tab — no page content]")
                continue
            }
            if tab.searchPage != nil {
                sections.append("\(header)\n\n[Search results page — no page content]")
                continue
            }
            if let content = await tab.extractVisibleText() {
                sections.append("\(header)\n\n\(content)")
            } else {
                sections.append("\(header)\n\n[No readable text available]")
            }
        }

        if sections.isEmpty {
            return "No tabs to read."
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    /// Saves a generated artifact and opens it in a new tab.
    func openArtifact(at url: URL) {
        let tab = BrowserTab()
        tabs.append(tab)
        select(tab)
        tab.loadArtifact(at: url)
        updateAddressFromSelectedTab()
    }

    /// Selects an existing tab whose loaded URL matches `fileURL`; opens a
    /// new tab with the artifact otherwise. Used by the chat tool-chain
    /// chip so users can re-enter an artifact without spawning duplicates.
    /// Comparison standardizes both sides because WKWebView's KVO observer
    /// reassigns `tab.url` to the WebKit-normalized URL after load.
    func openOrFocusArtifact(at fileURL: URL) {
        let target = fileURL.standardizedFileURL
        if let existing = tabs.first(where: { $0.url?.standardizedFileURL == target }) {
            select(existing)
            return
        }
        openArtifact(at: fileURL)
    }

    /// Runs the separate web-control agent against the tab that was selected
    /// when the tool started. The status is observed by the shell to draw the
    /// vignette and block user input while the harness is driving the page.
    func runWebControl(task: String, sessionDirectory: URL) async -> WebControlAgentOutcome {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            return WebControlAgentOutcome(
                succeeded: false,
                summary: "No web-control task was provided.",
                stepCount: 0
            )
        }

        let controlledTab = selectedTab
        webControlStatus = WebControlStatus(task: trimmedTask, detail: "Starting web agent", step: 0)
        defer { webControlStatus = nil }

        let runner = WebControlAgentRunner()
        return await runner.run(
            task: trimmedTask,
            tab: controlledTab,
            sessionDirectory: sessionDirectory
        ) { [weak self] status in
            self?.webControlStatus = status
        }
    }

    // MARK: - Tab hibernation

    /// Drops the WKWebView for any background tab that's been idle longer
    /// than the configured threshold. The tab row, its title/URL/favicon,
    /// and its Smart Read card all survive — clicking the row resurrects
    /// the tab and reloads the page. Selected, pinned-and-fresh, and
    /// non-navigable tabs are skipped.
    func hibernateIdleTabs(now: Date = Date()) {
        let minutes = UserDefaults.standard.integer(forKey: PreferenceKey.tabHibernationMinutes)
        guard minutes > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        for tab in tabs where tab.id != selectedTabID && !tab.isHibernated {
            if tab.lastActiveAt < cutoff {
                tab.hibernate()
            }
        }
    }

    private func startHibernationSweep() {
        hibernationSweepTask?.cancel()
        hibernationSweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BrowserModel.hibernationSweepInterval)
                guard !Task.isCancelled else { return }
                self?.hibernateIdleTabs()
            }
        }
    }
}
