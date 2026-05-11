import Combine
import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var clusters: [TabCluster] = []
    @Published var selectedTabID: BrowserTab.ID
    @Published var isTabRailVisible = true
    @Published var isChatVisible = true
    @Published var addressDraft = ""
    @Published var addressFocusToken = 0
    @Published var webControlStatus: WebControlStatus?

    private var tabChangeCancellables: [BrowserTab.ID: AnyCancellable] = [:]

    init() {
        let firstTab = BrowserTab()
        tabs = [firstTab]
        selectedTabID = firstTab.id
        configure(firstTab)
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
        selectedTabID = tab.id
        addressDraft = tab.displayAddress
    }

    func addTab() {
        let tab = makeTab()
        tabs.append(tab)
        select(tab)
    }

    /// Opens `url` in a freshly created tab. The new tab is appended to the
    /// list (pinned tabs always lead in the rail via ``TabRailView``'s sort).
    /// Set `background` to keep the current tab selected. Set `pinned` to
    /// mark the new tab as pinned — used by Hover Preview's "Pin" footer.
    func openInNewTab(url: URL, background: Bool = false, pinned: Bool = false) {
        let tab = makeTab()
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
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }

        let leavingClusterID = tab.clusterID
        tabs.remove(at: closingIndex)
        tab.setNewWindowHandler(nil)
        tabChangeCancellables[tab.id] = nil
        if let leavingClusterID {
            collapseClusterIfTooSmall(leavingClusterID)
        }

        if wasSelected {
            let nextIndex = min(closingIndex, tabs.count - 1)
            select(tabs[nextIndex])
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
        let tab = makeTab()
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

    private func makeTab() -> BrowserTab {
        let tab = BrowserTab()
        configure(tab)
        return tab
    }

    private func configure(_ tab: BrowserTab) {
        tab.setNewWindowHandler { [weak self] sourceTab, request in
            guard let self, let url = request.url else { return }
            self.openInNewTab(url: url, background: sourceTab.id != self.selectedTabID)
        }

        tabChangeCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
}

// MARK: - Tab clustering

@MainActor
extension BrowserModel {
    /// All tabs belonging to a cluster, in their current rail order.
    func tabs(in clusterID: UUID) -> [BrowserTab] {
        tabs.filter { $0.clusterID == clusterID }
    }

    /// Lookup helper for views — UUID → cluster.
    func cluster(id: UUID) -> TabCluster? {
        clusters.first(where: { $0.id == id })
    }

    /// Tap-to-collapse on a cluster header. The toggle lives on the model
    /// rather than each view so all rail copies (peek overlay, rail proper)
    /// stay synchronized.
    func toggleClusterExpansion(_ clusterID: UUID) {
        guard let index = clusters.firstIndex(where: { $0.id == clusterID }) else { return }
        clusters[index].isExpanded.toggle()
    }

    /// Renames an existing cluster from the cluster row's inline editor.
    /// Empty strings are rejected so the header never becomes invisible.
    func renameCluster(_ clusterID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = clusters.firstIndex(where: { $0.id == clusterID }) else { return }
        clusters[index].name = trimmed
    }

    /// Drag-to-merge entrypoint. `source` is the tab being dragged, `target`
    /// the row it was dropped on. Both inputs come from the rail; the model
    /// is responsible for choosing whether to extend an existing cluster or
    /// mint a new one, and for keeping cluster members contiguous in `tabs`.
    ///
    /// Magnetic mode kicks in only when a brand-new cluster forms from two
    /// tabs that share a host — that's the moment the user "declared the
    /// group's identity", so other matching same-host tabs adjacent to it
    /// get pulled in too.
    @discardableResult
    func mergeTabs(source: BrowserTab, into target: BrowserTab, magneticEnabled: Bool) -> UUID? {
        guard source.id != target.id else { return target.clusterID }

        if let targetClusterID = target.clusterID {
            attach(source, to: targetClusterID)
            return targetClusterID
        }

        if let sourceClusterID = source.clusterID {
            attach(target, to: sourceClusterID)
            return sourceClusterID
        }

        // The target acts as the anchor — drag-and-drop puts the dragged
        // tab onto the dropped one, so the resulting cluster identifies
        // with the target's host.
        let host = target.clusterHost ?? source.clusterHost ?? ""
        let name = host.isEmpty ? "Group" : TabCluster.displayName(forHost: host)
        let cluster = TabCluster(host: host, name: name)
        clusters.append(cluster)

        source.isPinned = false
        target.isPinned = false
        source.clusterID = cluster.id
        target.clusterID = cluster.id
        placeAdjacent(source: source, target: target)

        if magneticEnabled, source.clusterHost == target.clusterHost, source.clusterHost != nil {
            absorbAdjacentMatches(for: cluster.id)
        }
        return cluster.id
    }

    /// Drops a tab into a specific cluster. Used by drops on the cluster
    /// header itself (vs. dropping on a tab row).
    func attach(_ tab: BrowserTab, to clusterID: UUID) {
        guard clusters.contains(where: { $0.id == clusterID }) else { return }
        guard tab.clusterID != clusterID else { return }
        // `clusterID` is published on `BrowserTab`, not the model, so we
        // hand-fire the model's publisher to make sure ``railItems`` —
        // which reads `tab.clusterID` — gets recomputed even if the array
        // mutation below short-circuits (e.g., tab already in position).
        objectWillChange.send()
        let previousCluster = tab.clusterID
        tab.isPinned = false
        tab.clusterID = clusterID
        moveTabToEndOfCluster(tab, clusterID: clusterID)
        if let previousCluster {
            collapseClusterIfTooSmall(previousCluster)
        }
    }

    /// Removes a tab from its cluster without closing the tab. Currently
    /// reached via the cluster-row context menu / "ungroup" affordance.
    func detach(_ tab: BrowserTab) {
        guard let clusterID = tab.clusterID else { return }
        // Cluster-id mutations live on the tab, not the model — nudge so
        // the rail recomputes even when the cluster still has ≥2 members
        // after this detach (no `clusters` array mutation triggers it).
        objectWillChange.send()
        tab.clusterID = nil
        collapseClusterIfTooSmall(clusterID)
    }

    /// Dissolves a cluster (preserving the underlying tabs as loose rows).
    func dissolveCluster(_ clusterID: UUID) {
        objectWillChange.send()
        for tab in tabs where tab.clusterID == clusterID {
            tab.clusterID = nil
        }
        clusters.removeAll { $0.id == clusterID }
    }

    /// Closes every tab inside a cluster. Mirrors `close(_:)` for safety
    /// when the cluster contains the only remaining tab.
    func closeCluster(_ clusterID: UUID) {
        let members = tabs.filter { $0.clusterID == clusterID }
        for tab in members {
            close(tab)
        }
        clusters.removeAll { $0.id == clusterID }
    }

    // MARK: - Private helpers

    /// Places `source` immediately after `target` in `tabs` so the rail
    /// renders the two as adjacent rows inside the freshly-minted cluster.
    /// The captured target index needs adjustment when the source was
    /// originally before the target — pulling it out shifts the target
    /// down by one, so the "right-after-target" insertion has to compensate.
    private func placeAdjacent(source: BrowserTab, target: BrowserTab) {
        guard let targetIndex = tabs.firstIndex(where: { $0.id == target.id }),
              let sourceIndex = tabs.firstIndex(where: { $0.id == source.id }) else { return }
        tabs.removeAll { $0.id == source.id }
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        let insertionIndex = min(adjustedTarget + 1, tabs.count)
        tabs.insert(source, at: insertionIndex)
    }

    /// Moves `tab` to sit right after the last existing cluster member so
    /// rail items stay contiguous.
    private func moveTabToEndOfCluster(_ tab: BrowserTab, clusterID: UUID) {
        guard let lastClusterIndex = tabs.lastIndex(where: { $0.clusterID == clusterID && $0.id != tab.id }) else { return }
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if currentIndex == lastClusterIndex + 1 { return }
        let toMove = tabs.remove(at: currentIndex)
        let targetIndex = tabs.lastIndex(where: { $0.clusterID == clusterID }).map { $0 + 1 } ?? tabs.count
        tabs.insert(toMove, at: min(targetIndex, tabs.count))
    }

    /// "Magnetic" pass run once at cluster birth. Vacuums every loose tab
    /// in the rail that shares the cluster's host into the cluster, then
    /// re-anchors them to sit contiguously around the existing members so
    /// the rail reads as one tidy group. Tabs that already belong to a
    /// different cluster, or that are pinned, are left alone.
    private func absorbAdjacentMatches(for clusterID: UUID) {
        guard let cluster = self.cluster(id: clusterID) else { return }
        let host = cluster.host
        guard !host.isEmpty else { return }

        let absorbing = tabs.filter { tab in
            tab.clusterID == nil && !tab.isPinned && tab.clusterHost == host
        }
        guard !absorbing.isEmpty else { return }

        for tab in absorbing {
            tab.clusterID = clusterID
        }

        // Re-pack: move every cluster member to sit in one contiguous run
        // starting at the position of the original first cluster tab.
        let anchorIndex = tabs.firstIndex(where: { $0.clusterID == clusterID }) ?? tabs.count
        let members = tabs.filter { $0.clusterID == clusterID }
        tabs.removeAll { $0.clusterID == clusterID }
        let clampedAnchor = min(anchorIndex, tabs.count)
        tabs.insert(contentsOf: members, at: clampedAnchor)
    }

    /// A cluster with fewer than 2 members offers nothing over a loose
    /// tab, so we dissolve it back into singletons when membership dips
    /// below 2 (e.g., closing one of two cluster tabs).
    private func collapseClusterIfTooSmall(_ clusterID: UUID) {
        let remaining = tabs.filter { $0.clusterID == clusterID }
        if remaining.count >= 2 { return }
        for tab in remaining { tab.clusterID = nil }
        clusters.removeAll { $0.id == clusterID }
    }
}
