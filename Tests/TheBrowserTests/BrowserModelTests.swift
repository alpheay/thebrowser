import Combine
import Foundation
import Testing
@testable import TheBrowser

@Suite("Browser model")
struct BrowserModelTests {
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
