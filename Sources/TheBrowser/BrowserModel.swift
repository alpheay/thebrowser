import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var selectedTabID: BrowserTab.ID
    @Published var isTabRailVisible = true
    @Published var isChatVisible = true
    @Published var addressDraft = ""

    init() {
        let firstTab = BrowserTab()
        tabs = [firstTab]
        selectedTabID = firstTab.id
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
        let tab = BrowserTab()
        tabs.append(tab)
        select(tab)
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
}
