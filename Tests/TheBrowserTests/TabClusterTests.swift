import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("Tab cluster merging")
struct TabClusterTests {
    @Test("Drag-merging two same-host tabs forms a cluster named after the host")
    func mergeSameHostTabsCreatesCluster() {
        let model = makeModel(hosts: [nil, "github.com", "github.com"])
        let tabs = model.tabs

        _ = model.mergeTabs(source: tabs[1], into: tabs[2], magneticEnabled: false)

        #expect(model.clusters.count == 1)
        #expect(model.clusters.first?.host == "github.com")
        #expect(model.clusters.first?.name == "Github")
        #expect(tabs[1].clusterID != nil)
        #expect(tabs[1].clusterID == tabs[2].clusterID)
    }

    @Test("Cluster members are contiguous in the tabs array after merge")
    func clusterMembersStayContiguous() {
        let model = makeModel(hosts: [
            "github.com",   // 0
            "reddit.com",   // 1
            "github.com"    // 2
        ])
        let tabs = model.tabs
        let github1 = tabs[0]
        let github2 = tabs[2]

        _ = model.mergeTabs(source: github1, into: github2, magneticEnabled: false)

        let positions = model.tabs.enumerated().filter { $0.element.clusterID != nil }.map(\.offset)
        let span = (positions.max() ?? 0) - (positions.min() ?? 0)
        #expect(span == positions.count - 1, "cluster members must occupy a contiguous range")
    }

    @Test("Magnetic mode pulls every loose same-host tab into the new cluster")
    func magneticPullsMatchingTabs() {
        let model = makeModel(hosts: [
            "github.com",   // 0
            "reddit.com",   // 1
            "github.com",   // 2
            "github.com",   // 3 (target)
            "reddit.com",   // 4
            "github.com"    // 5
        ])
        let tabs = model.tabs

        _ = model.mergeTabs(source: tabs[2], into: tabs[3], magneticEnabled: true)

        let githubClusterID = tabs[2].clusterID
        #expect(githubClusterID != nil)
        let clustered = model.tabs.filter { $0.clusterID == githubClusterID }
        #expect(clustered.count == 4, "all four github tabs should join the cluster")
        let reddits = model.tabs.filter { $0.clusterHost == "reddit.com" }
        #expect(reddits.allSatisfy { $0.clusterID == nil }, "reddit tabs must stay loose")
    }

    @Test("Magnetic mode off only clusters the two dragged tabs")
    func nonMagneticLeavesOthersLoose() {
        let model = makeModel(hosts: [
            "github.com",
            "github.com",
            "github.com"
        ])
        let tabs = model.tabs

        _ = model.mergeTabs(source: tabs[0], into: tabs[1], magneticEnabled: false)

        #expect(tabs[0].clusterID != nil)
        #expect(tabs[1].clusterID != nil)
        #expect(tabs[2].clusterID == nil, "the third tab stays loose without magnetic mode")
    }

    @Test("Magnetic mode does not fire when the two seed tabs have different hosts")
    func magneticSkipsMixedHostSeed() {
        let model = makeModel(hosts: [
            "github.com",
            "reddit.com",
            "github.com"   // would have been absorbed if seed shared host
        ])
        let tabs = model.tabs

        _ = model.mergeTabs(source: tabs[0], into: tabs[1], magneticEnabled: true)

        #expect(tabs[2].clusterID == nil, "third tab must stay loose — the seed cluster wasn't single-host")
    }

    @Test("Closing the second-to-last cluster member dissolves the cluster")
    func closingCollapsesSingletonCluster() {
        let model = makeModel(hosts: [
            "github.com",
            "github.com",
            "reddit.com"
        ])
        let tabs = model.tabs
        _ = model.mergeTabs(source: tabs[0], into: tabs[1], magneticEnabled: false)
        let cluster = model.clusters.first
        #expect(cluster != nil)

        // Close one of the two cluster members — the survivor should pop
        // back out as a loose tab and the cluster row should vanish.
        model.close(tabs[0])

        #expect(model.clusters.isEmpty, "cluster with <2 members must dissolve")
        let survivor = model.tabs.first { $0 === tabs[1] }
        #expect(survivor?.clusterID == nil)
    }

    @Test("Detach removes a tab from its cluster without closing it")
    func detachUngroupsButKeepsTab() {
        let model = makeModel(hosts: [
            "github.com",
            "github.com",
            "github.com"
        ])
        let tabs = model.tabs
        _ = model.mergeTabs(source: tabs[0], into: tabs[1], magneticEnabled: true)
        let clusterID = tabs[0].clusterID
        #expect(clusterID != nil)
        // All three should be clustered with magnetic on.
        #expect(model.tabs.filter { $0.clusterID == clusterID }.count == 3)

        model.detach(tabs[0])

        #expect(tabs[0].clusterID == nil)
        #expect(model.clusters.first?.id == clusterID, "cluster persists with the remaining two members")
        #expect(model.tabs.contains(where: { $0 === tabs[0] }), "detached tab stays in the rail")
    }

    @Test("Toggling cluster expansion flips the published state")
    func expansionTogglesPublishedState() {
        let model = makeModel(hosts: ["github.com", "github.com"])
        let tabs = model.tabs
        _ = model.mergeTabs(source: tabs[0], into: tabs[1], magneticEnabled: false)
        let clusterID = model.clusters[0].id
        #expect(model.clusters[0].isExpanded)

        model.toggleClusterExpansion(clusterID)
        #expect(!model.clusters[0].isExpanded)
    }

    // MARK: - Helpers

    private func makeModel(hosts: [String?]) -> BrowserModel {
        let model = BrowserModel()
        // Drop the default empty tab so the test starts from a clean slate.
        let starter = model.tabs[0]

        for (index, host) in hosts.enumerated() {
            if index == 0 {
                if let host { starter.navigate(to: "https://\(host)/seed") }
            } else {
                let tab = BrowserTab()
                if let host { tab.navigate(to: "https://\(host)/seed") }
                model.tabs.append(tab)
            }
        }
        return model
    }
}
