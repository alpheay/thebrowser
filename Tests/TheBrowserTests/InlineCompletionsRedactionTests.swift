import Foundation
import Testing
@testable import TheBrowser

@Suite("InlineCompletionsRedaction")
struct InlineCompletionsRedactionTests {
    @Test("Returns input unchanged when no secrets are present")
    func noSecretsLeavesTextAlone() {
        let result = InlineCompletionsRedaction.redact("Just a normal sentence about cats.")
        #expect(result.text == "Just a normal sentence about cats.")
        #expect(result.didRedact == false)
    }

    @Test("Empty input is a noop")
    func emptyInputIsNoop() {
        let result = InlineCompletionsRedaction.redact("")
        #expect(result.text == "")
        #expect(result.didRedact == false)
    }

    @Test("Anthropic / OpenAI style keys are redacted")
    func anthropicStyleKeyRedacted() {
        let result = InlineCompletionsRedaction.redact("My key is sk-ant-1234567890abcdef0987654321 and here")
        #expect(result.didRedact == true)
        #expect(result.text.contains("[REDACTED]"))
        #expect(result.text.contains("sk-ant") == false)
    }

    @Test("AWS access key IDs are redacted")
    func awsKeyRedacted() {
        let result = InlineCompletionsRedaction.redact("AKIAIOSFODNN7EXAMPLE was leaked")
        #expect(result.didRedact == true)
        #expect(result.text.contains("AKIA") == false)
    }

    @Test("GitHub personal access tokens are redacted")
    func githubTokenRedacted() {
        let result = InlineCompletionsRedaction.redact("token=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa go")
        #expect(result.didRedact == true)
        #expect(result.text.contains("ghp_") == false)
    }

    @Test("JWT-shaped tokens are redacted")
    func jwtRedacted() {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let result = InlineCompletionsRedaction.redact("Bearer \(token) thanks")
        #expect(result.didRedact == true)
        #expect(result.text.contains("eyJ") == false)
    }

    @Test("Credit-card-shaped digit runs are redacted")
    func creditCardShapeRedacted() {
        let result = InlineCompletionsRedaction.redact("Charge to 4111 1111 1111 1111 today")
        #expect(result.didRedact == true)
        #expect(result.text.contains("[REDACTED]"))
    }

    @Test("Slack tokens are redacted")
    func slackTokenRedacted() {
        let result = InlineCompletionsRedaction.redact("Webhook xoxb-1234567890-abc-defghij arrived")
        #expect(result.didRedact == true)
        #expect(result.text.contains("xoxb-") == false)
    }

    @Test("Multiple secret kinds in one string all get redacted")
    func multiplePatternsRedacted() {
        let input = "AKIAIOSFODNN7EXAMPLE and sk-abc1234567890abcdef0987 mixed together"
        let result = InlineCompletionsRedaction.redact(input)
        #expect(result.didRedact == true)
        #expect(result.text.contains("AKIA") == false)
        #expect(result.text.contains("sk-abc") == false)
    }
}

@Suite("InlineCompletionsSettings.allows(host:)")
struct InlineCompletionsSettingsTests {
    private func make(
        enabled: Bool = true,
        allow: [String] = [],
        block: [String] = []
    ) -> InlineCompletionsSettings {
        InlineCompletionsSettings(
            isEnabled: enabled,
            triggerDelayMs: 600,
            renderMode: "ghost",
            allowList: allow,
            blockList: block
        )
    }

    @Test("Disabled settings reject every host")
    func disabledRejectsEverything() {
        let settings = make(enabled: false, allow: ["github.com"])
        #expect(settings.allows(host: "github.com") == false)
    }

    @Test("Empty allowlist means every host is allowed unless blocked")
    func emptyAllowAllowsAll() {
        let settings = make()
        #expect(settings.allows(host: "example.com") == true)
        #expect(settings.allows(host: "mail.google.com") == true)
    }

    @Test("Block list takes precedence over allow list")
    func blockBeatsAllow() {
        let settings = make(allow: ["github.com"], block: ["github.com"])
        #expect(settings.allows(host: "github.com") == false)
    }

    @Test("Hostname suffix matching covers subdomains")
    func suffixMatchesSubdomains() {
        let settings = make(allow: ["slack.com"])
        #expect(settings.allows(host: "app.slack.com") == true)
        #expect(settings.allows(host: "slack.com") == true)
        #expect(settings.allows(host: "fakeslack.com") == false)
    }

    @Test("Empty host is never allowed")
    func emptyHostRejected() {
        let settings = make()
        #expect(settings.allows(host: "") == false)
    }
}
