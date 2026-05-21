import Combine
import Foundation
import Testing
@testable import TheBrowser

@Suite("Browser model")
struct BrowserModelTests {
    @MainActor
    @Test("Model starts with AI and tab sidebars closed")
    func modelStartsWithSidebarsClosed() {
        let model = BrowserModel()

        #expect(!model.isChatVisible)
        #expect(!model.isTabRailVisible)
    }

    @MainActor
    @Test("Model forwards selected tab state changes")
    func modelForwardsTabChanges() async {
        let model = BrowserModel()
        var changeCount = 0
        let cancellable = model.objectWillChange.sink {
            changeCount += 1
        }

        model.selectedTab.isHome = false
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(changeCount > 0)
        _ = cancellable
    }

    @MainActor
    @Test("Closing selected tab selects its neighbor")
    func closingSelectedTabSelectsNeighbor() {
        let model = BrowserModel()
        let first = model.tabs[0]

        model.addTab()
        let second = model.tabs[1]

        model.addTab()
        let third = model.tabs[2]

        model.select(first)
        model.close(first)

        #expect(model.selectedTabID == second.id)
        #expect(model.selectedTabID != third.id)
    }

    @MainActor
    @Test("Hibernation unloads stale background tabs but not the selected tab")
    func hibernationUnloadsOnlyStaleBackgroundTabs() {
        let previousDefault = UserDefaults.standard.object(forKey: PreferenceKey.tabHibernationMinutes)
        defer {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: PreferenceKey.tabHibernationMinutes)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferenceKey.tabHibernationMinutes)
            }
        }

        UserDefaults.standard.set(30, forKey: PreferenceKey.tabHibernationMinutes)

        let model = BrowserModel()
        let first = model.tabs[0]
        first.isHome = false
        first.url = URL(string: "https://example.com/old")

        model.addTab()
        let selected = model.selectedTab
        selected.isHome = false
        selected.url = URL(string: "https://example.com/current")
        first.lastActiveAt = Date(timeIntervalSince1970: 0)
        selected.lastActiveAt = Date(timeIntervalSince1970: 0)

        model.hibernateIdleTabs(now: Date(timeIntervalSince1970: 60 * 31))

        #expect(first.isHibernated)
        #expect(!selected.isHibernated)
    }

    @MainActor
    @Test("Hibernation resets in-flight Smart Read but keeps completed summaries")
    func hibernationHandlesSmartReadState() {
        let loadingTab = BrowserTab()
        loadingTab.isHome = false
        loadingTab.url = URL(string: "https://example.com/loading")
        loadingTab.smartReadIsPresented = true
        loadingTab.smartReadPhase = .loading(title: "Loading")

        loadingTab.hibernate()

        #expect(loadingTab.isHibernated)
        #expect(!loadingTab.smartReadIsPresented)
        #expect(loadingTab.smartReadPhase == .idle)

        let loadedResult = SmartReadResult(
            tldr: "A short summary.",
            keyPoints: ["One", "Two", "Three"],
            readTimeMinutes: 2,
            wordCount: 420,
            title: "Loaded",
            url: "https://example.com/loaded"
        )
        let loadedTab = BrowserTab()
        loadedTab.isHome = false
        loadedTab.url = URL(string: loadedResult.url)
        loadedTab.smartReadIsPresented = true
        loadedTab.smartReadPhase = .loaded(loadedResult)

        loadedTab.hibernate()

        #expect(loadedTab.isHibernated)
        #expect(loadedTab.smartReadIsPresented)
        #expect(loadedTab.smartReadPhase == .loaded(loadedResult))
    }

    @Test("Address resolver treats bare localhost ports as HTTP URLs")
    func localhostPortUsesHTTP() {
        #expect(AddressResolver.url(for: "localhost:5173")?.absoluteString == "http://localhost:5173")
        #expect(AddressResolver.url(for: "127.0.0.1:3000")?.absoluteString == "http://127.0.0.1:3000")
        #expect(AddressResolver.url(for: "example.com:8080")?.absoluteString == "http://example.com:8080")
    }

    @Test("Address resolver does not treat arbitrary colon text as a URL scheme")
    func arbitraryColonTextBecomesSearch() {
        guard case .search(let query) = AddressResolver.destination(for: "foo:bar") else {
            Issue.record("Expected arbitrary colon text to resolve as search")
            return
        }

        #expect(query == "foo:bar")
    }
}
