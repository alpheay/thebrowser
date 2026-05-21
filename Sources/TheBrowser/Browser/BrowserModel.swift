import AppKit
import Combine
import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var selectedTabID: BrowserTab.ID
    @Published private(set) var currentThreadID: UUID?
    @Published private(set) var currentThread: ThreadRecord?
    @Published private(set) var availableThreads: [ThreadRecord] = []
    @Published var isThreadPickerVisible = false
    @Published var isTabRailVisible = false
    @Published var isChatVisible = false
    @Published var addressDraft = ""
    @Published var addressFocusToken = 0
    @Published var webControlStatus: WebControlStatus?

    /// Cadence (seconds) at which the background sweep walks the tab list
    /// and hibernates anything past the idle threshold. Sixty seconds is
    /// short enough that a 30-minute setting feels exact and long enough
    /// that the sweep itself is invisible.
    private static let hibernationSweepInterval: UInt64 = 60_000_000_000
    private static let threadPersistenceDebounce: UInt64 = 500_000_000
    private let threadStore: ThreadStore
    private var hibernationSweepTask: Task<Void, Never>?
    private var threadPersistenceTask: Task<Void, Never>?
    private var threadRestoreTask: Task<Void, Never>?
    private var tabChangeCancellables: [BrowserTab.ID: AnyCancellable] = [:]
    private weak var window: NSWindow?

    init(
        threadStore: ThreadStore = .shared,
        initialThreadID: UUID? = nil,
        restoresThreads: Bool = false
    ) {
        self.threadStore = threadStore
        let firstTab = BrowserTab()
        tabs = [firstTab]
        selectedTabID = firstTab.id
        configure(firstTab)
        startHibernationSweep()
        if restoresThreads {
            restoreThreadsOnLaunch(initialThreadID: initialThreadID)
        }
    }

    deinit {
        hibernationSweepTask?.cancel()
        threadPersistenceTask?.cancel()
        threadRestoreTask?.cancel()
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

    var threadTitle: String {
        currentThread?.title ?? "New Thread"
    }

    var threadAgentContext: String {
        currentThread?.agentContext ?? ""
    }

    var threadScratchDirectory: URL {
        if let path = currentThread?.scratchDirPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return ThreadScratchDirectory.url(for: currentThreadID ?? UUID())
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
        scheduleThreadPersistence()
    }

    func addTab() {
        let tab = makeTab()
        tabs.append(tab)
        select(tab)
        scheduleThreadPersistence()
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
        scheduleThreadPersistence()
    }

    func close(_ tab: BrowserTab) {
        guard tabs.count > 1 else {
            tab.goHome()
            addressDraft = ""
            scheduleThreadPersistence()
            return
        }

        let wasSelected = tab.id == selectedTabID
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }

        tabs.remove(at: closingIndex)
        tab.setNewWindowHandler(nil)
        tab.setStateChangeHandler(nil)
        tabChangeCancellables[tab.id] = nil

        if wasSelected {
            let nextIndex = min(closingIndex, tabs.count - 1)
            select(tabs[nextIndex])
        }
        scheduleThreadPersistence()
    }

    func closeSelected() {
        close(selectedTab)
    }

    func navigateSelected(to input: String? = nil) {
        let target = input ?? addressDraft
        selectedTab.navigate(to: target)
        addressDraft = selectedTab.displayAddress
        scheduleThreadPersistence()
    }

    func goHome() {
        selectedTab.goHome()
        addressDraft = ""
        scheduleThreadPersistence()
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

    func attachWindow(_ window: NSWindow) {
        self.window = window
        if let currentThreadID {
            ThreadWindowRegistry.shared.register(threadID: currentThreadID, window: window)
        }
    }

    func restoreThreadsOnLaunch(initialThreadID: UUID? = nil) {
        threadRestoreTask?.cancel()
        threadRestoreTask = Task { @MainActor [weak self] in
            await self?.loadInitialThread(initialThreadID: initialThreadID)
        }
    }

    func showThreadPicker() {
        refreshThreadList()
        isThreadPickerVisible = true
    }

    func cycleThread(forward: Bool) {
        guard availableThreads.count > 1 else { return }
        let ordered = availableThreads
        let currentIndex = ordered.firstIndex { $0.id == currentThreadID } ?? 0
        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % ordered.count
        } else {
            nextIndex = (currentIndex - 1 + ordered.count) % ordered.count
        }
        switchToThread(id: ordered[nextIndex].id)
    }

    func switchToThread(id: UUID) {
        guard id != currentThreadID else {
            isThreadPickerVisible = false
            return
        }
        Task { @MainActor [weak self] in
            await self?.switchToThreadAsync(id: id)
        }
    }

    func createThreadAndSwitch() {
        Task { @MainActor [weak self] in
            await self?.createThreadAndSwitchAsync()
        }
    }

    func closeCurrentThread() {
        guard let id = currentThreadID else { return }
        let context = currentThread?.agentContext ?? ""
        if let agentContext = ThreadAgentContext(serialized: context) {
            ChatSessionStore.shared.delete(sessionID: agentContext.sessionID)
        }
        Task { @MainActor [weak self] in
            await self?.deleteThreadAndSelectReplacement(id: id)
        }
    }

    func updateAgentContext(_ serializedContext: String) {
        guard let id = currentThreadID,
              currentThread?.agentContext != serializedContext else {
            return
        }
        if var thread = currentThread {
            thread.agentContext = serializedContext
            currentThread = thread
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let updated = try await self.threadStore.updateAgentContext(
                    id: id,
                    agentContext: serializedContext
                ) {
                    self.currentThread = updated
                    await self.reloadThreadList()
                }
            } catch {
                #if DEBUG
                print("BrowserModel: failed to persist thread agent context: \(error)")
                #endif
            }
        }
    }

    func markThreadWindowOpen() {
        guard let id = currentThreadID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.threadStore.markWindowOpen(id: id, isOpen: true)
                await self.reloadThreadList()
            } catch {
                #if DEBUG
                print("BrowserModel: failed to mark thread open: \(error)")
                #endif
            }
        }
    }

    func markThreadWindowClosed(isTerminating: Bool) {
        if let currentThreadID {
            ThreadWindowRegistry.shared.unregister(threadID: currentThreadID, window: window)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistTabsNow()
            guard !isTerminating, let id = self.currentThreadID else { return }
            do {
                _ = try await self.threadStore.markWindowOpen(id: id, isOpen: false)
            } catch {
                #if DEBUG
                print("BrowserModel: failed to mark thread closed: \(error)")
                #endif
            }
        }
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

    /// ⌘D entry point. Selects an existing Discord tab if there is one;
    /// otherwise creates a fresh one. Either way, the tab's webview is
    /// reloaded with `reloadIgnoringLocalAndRemoteCacheData` so a stale or
    /// half-broken cached response (the "sometimes Discord doesn't load"
    /// failure mode) is bypassed every time the shortcut fires.
    func openOrFocusDiscord() {
        let entryURL = URL(string: "https://discord.com/channels/@me")!

        if let existing = tabs.first(where: { $0.isDiscord }) {
            select(existing)
            existing.webView.load(URLRequest(
                url: existing.url ?? entryURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
            ))
            return
        }

        let tab = makeTab()
        tabs.append(tab)
        select(tab)
        // Mirror the bookkeeping `navigate(to:)` does, then issue the
        // cache-bypassing load directly.
        tab.isHome = false
        tab.searchPage = nil
        tab.loadError = nil
        tab.url = entryURL
        tab.title = "Discord"
        tab.webView.load(URLRequest(
            url: entryURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        ))
        updateAddressFromSelectedTab()
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

    func persistTabsNow() async {
        threadPersistenceTask?.cancel()
        threadPersistenceTask = nil
        await saveTabsToCurrentThread()
    }

    private func loadInitialThread(initialThreadID: UUID?) async {
        do {
            let threads = try await threadStore.list()
            availableThreads = threads

            if let initialThreadID,
               let thread = try await threadStore.get(id: initialThreadID) {
                guard load(thread: thread) else {
                    window?.close()
                    return
                }
                _ = try await threadStore.markWindowOpen(id: thread.id, isOpen: true)
                await reloadThreadList()
                return
            }

            if threads.isEmpty {
                let created = try await threadStore.create(isWindowOpen: true)
                _ = load(thread: created)
                await reloadThreadList()
                return
            }

            let openThreads = threads.filter(\.isWindowOpen)
            let chosen = openThreads.count == 1 ? openThreads[0] : threads[0]
            guard load(thread: chosen) else {
                window?.close()
                return
            }
            _ = try await threadStore.markWindowOpen(id: chosen.id, isOpen: true)
            await reloadThreadList()

            if threads.count > 1 || openThreads.count > 1 {
                isThreadPickerVisible = true
            }
        } catch {
            #if DEBUG
            print("BrowserModel: failed to restore threads: \(error)")
            #endif
        }
    }

    private func switchToThreadAsync(id: UUID) async {
        await persistTabsNow()
        if let currentThreadID {
            _ = try? await threadStore.markWindowOpen(id: currentThreadID, isOpen: false)
        }

        do {
            guard let thread = try await threadStore.get(id: id) else { return }
            guard load(thread: thread) else {
                isThreadPickerVisible = false
                return
            }
            _ = try await threadStore.markWindowOpen(id: id, isOpen: true)
            await reloadThreadList()
            isThreadPickerVisible = false
        } catch {
            #if DEBUG
            print("BrowserModel: failed to switch thread: \(error)")
            #endif
        }
    }

    private func createThreadAndSwitchAsync() async {
        await persistTabsNow()
        if let currentThreadID {
            _ = try? await threadStore.markWindowOpen(id: currentThreadID, isOpen: false)
        }

        do {
            let thread = try await threadStore.create(isWindowOpen: true)
            _ = load(thread: thread)
            await reloadThreadList()
            isThreadPickerVisible = false
        } catch {
            #if DEBUG
            print("BrowserModel: failed to create thread: \(error)")
            #endif
        }
    }

    private func deleteThreadAndSelectReplacement(id: UUID) async {
        await persistTabsNow()
        do {
            try await threadStore.delete(id: id)
            let remaining = try await threadStore.list()
            if let next = remaining.first {
                _ = load(thread: next)
                _ = try await threadStore.markWindowOpen(id: next.id, isOpen: true)
            } else {
                let created = try await threadStore.create(isWindowOpen: true)
                _ = load(thread: created)
            }
            await reloadThreadList()
            isThreadPickerVisible = false
        } catch {
            #if DEBUG
            print("BrowserModel: failed to close thread: \(error)")
            #endif
        }
    }

    private func refreshThreadList() {
        Task { @MainActor [weak self] in
            await self?.reloadThreadList()
        }
    }

    private func reloadThreadList() async {
        do {
            availableThreads = try await threadStore.list()
        } catch {
            #if DEBUG
            print("BrowserModel: failed to reload thread list: \(error)")
            #endif
        }
    }

    @discardableResult
    private func load(thread: ThreadRecord) -> Bool {
        if thread.id != currentThreadID,
           ThreadWindowRegistry.shared.focus(threadID: thread.id) {
            return false
        }

        threadPersistenceTask?.cancel()
        threadPersistenceTask = nil

        if let currentThreadID {
            ThreadWindowRegistry.shared.unregister(threadID: currentThreadID, window: window)
        }

        for tab in tabs {
            tab.setNewWindowHandler(nil)
            tab.setStateChangeHandler(nil)
            tab.setLinkHoverListener(nil)
        }
        tabChangeCancellables.removeAll()

        currentThreadID = thread.id
        currentThread = thread
        let restoredTabs = thread.tabs.isEmpty
            ? [BrowserTab()]
            : thread.tabs.map(BrowserTab.init(snapshot:))
        tabs = restoredTabs
        selectedTabID = restoredTabs[0].id
        for tab in restoredTabs {
            configure(tab)
        }
        updateAddressFromSelectedTab()
        if let window {
            ThreadWindowRegistry.shared.register(threadID: thread.id, window: window)
        }
        objectWillChange.send()
        return true
    }

    private func scheduleThreadPersistence() {
        guard currentThreadID != nil else { return }
        threadPersistenceTask?.cancel()
        threadPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: BrowserModel.threadPersistenceDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveTabsToCurrentThread()
        }
    }

    private func saveTabsToCurrentThread() async {
        guard let id = currentThreadID else { return }
        let snapshots = tabs.map { $0.snapshotForThread() }
        do {
            if let updated = try await threadStore.updateTabs(id: id, tabs: snapshots) {
                currentThread = updated
                await reloadThreadList()
            }
        } catch {
            #if DEBUG
            print("BrowserModel: failed to persist thread tabs: \(error)")
            #endif
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

        tab.setStateChangeHandler { [weak self] _ in
            self?.scheduleThreadPersistence()
        }

        let tabSink = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        // The find controller is a separate ObservableObject — its
        // publishes don't propagate through the tab, so the shell view
        // can't see find-bar state changes without this second sink.
        let findSink = tab.findController.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        tabChangeCancellables[tab.id] = AnyCancellable {
            tabSink.cancel()
            findSink.cancel()
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
