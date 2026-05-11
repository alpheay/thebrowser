import Foundation
import Testing
@testable import TheBrowser

@Suite("CitedClipboardPolicy")
struct CitedClipboardPolicyTests {
    @Test("Empty host always blocks — there's no provenance to attach")
    func emptyHostBlocks() {
        #expect(CitedClipboardPolicy.isBlocked(host: "", blocklist: ["bankofamerica.com"]))
    }

    @Test("Exact host equality matches a blocklist entry")
    func exactHostMatch() {
        #expect(CitedClipboardPolicy.isBlocked(host: "bankofamerica.com", blocklist: ["bankofamerica.com"]))
    }

    @Test("Subdomain matches when the entry is the parent domain")
    func subdomainMatch() {
        #expect(CitedClipboardPolicy.isBlocked(host: "secure.bankofamerica.com", blocklist: ["bankofamerica.com"]))
    }

    @Test("Sibling domains that share a TLD label do not match")
    func siblingHostNoMatch() {
        #expect(!CitedClipboardPolicy.isBlocked(host: "evilbankofamerica.com", blocklist: ["bankofamerica.com"]))
    }

    @Test("Non-blocklisted hosts go through")
    func unrelatedHostNoMatch() {
        #expect(!CitedClipboardPolicy.isBlocked(host: "github.com", blocklist: ["bankofamerica.com"]))
    }

    @Test("parseBlocklist normalizes whitespace, casing, and comments")
    func parseBlocklistNormalizes() {
        let raw = """
            BankOfAmerica.com
            # Banking
            wellsFARGO.com
                ,, capitalone.com
            \t
        """
        let parsed = CitedClipboardPolicy.parseBlocklist(raw)
        #expect(parsed == ["bankofamerica.com", "wellsfargo.com", "capitalone.com"])
    }

    @Test("Default starter list covers obvious sensitive categories")
    func defaultBlocklistCoversSensitiveCategories() {
        let list = CitedClipboardPolicy.defaultBlocklist
        #expect(list.contains("chase.com"))
        #expect(list.contains("mychart.com"))
        #expect(list.contains("1password.com"))
        #expect(list.contains("accounts.google.com"))
    }
}
