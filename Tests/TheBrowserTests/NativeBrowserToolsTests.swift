import Foundation
import Testing
@testable import TheBrowser

@Suite("Native browser tools")
struct NativeBrowserToolsTests {
    @Test("Parses flat tool call JSON")
    func parsesFlatToolCall() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"open","url":"https://youtube.com"}"#))

        #expect(call.name == .open)
        #expect(call.url == "https://youtube.com")
    }

    @Test("Parses harness-style name plus arguments JSON inside a fence")
    func parsesArgumentsToolCall() throws {
        let response = """
        ```browser_tool
        {"name":"search","arguments":{"query":"best ramen brooklyn"}}
        ```
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .search)
        #expect(call.query == "best ramen brooklyn")
    }

    @Test("Ignores normal assistant prose")
    func ignoresNormalProse() {
        #expect(NativeBrowserToolCall.parse(from: "I can help with that.") == nil)
    }

    @Test("Ignores JSON examples embedded in prose")
    func ignoresEmbeddedJSONExamples() {
        let response = #"I can use open like {"tool":"open","url":"https://example.com"} when needed."#

        #expect(NativeBrowserToolCall.parse(from: response) == nil)
    }

    @Test("Parses a trailing tool call that follows leading prose on a new line")
    func parsesTrailingToolCallAfterProse() throws {
        let response = """
        That looks like it might be "GT Canvas" (Georgia Tech Canvas). Let me open that for you.
        {"tool":"open","url":"https://canvas.gatech.edu"}
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://canvas.gatech.edu")
    }

    @Test("Parses a trailing tool call when prose contains brace-like text")
    func parsesTrailingToolCallWithBracesInProse() throws {
        let response = """
        Some folks write sets like {a, b, c} — anyway, opening that now.
        {"tool":"open","url":"https://example.com"}
        """

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://example.com")
    }

    @Test("Picks the trailing tool call when a JSON example also appears mid-prose")
    func prefersTrailingToolCallOverEmbeddedExample() throws {
        let response = #"""
        You can call it like {"tool":"open","url":"https://example.com"} — here goes:
        {"tool":"open","url":"https://canvas.gatech.edu"}
        """#

        let call = try #require(NativeBrowserToolCall.parse(from: response))

        #expect(call.name == .open)
        #expect(call.url == "https://canvas.gatech.edu")
    }

    @Test("Ignores a JSON object that is not the last non-whitespace content")
    func ignoresJSONFollowedByMoreProse() {
        let response = #"{"tool":"open","url":"https://example.com"} — let me know if that's right."#

        #expect(NativeBrowserToolCall.parse(from: response) == nil)
    }

    @MainActor
    @Test("Open tool navigates through the injected browser action")
    func openToolInvokesNavigation() async {
        var openedURL: URL?
        let executor = NativeBrowserToolExecutor(
            openURL: { url in openedURL = url },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )
        let result = await executor.execute(
            NativeBrowserToolCall(name: .open, url: "youtube.com")
        )

        #expect(result.succeeded)
        #expect(openedURL?.absoluteString == "https://youtube.com")
    }

    @Test("Continuation prompt includes tool results and asks for normal answer")
    func continuationPromptIncludesToolResult() {
        let result = NativeBrowserToolResult(
            call: NativeBrowserToolCall(name: .open, url: "https://example.com"),
            succeeded: true,
            content: "Opened https://example.com in the current tab."
        )

        let prompt = NativeBrowserToolPrompt.continuationPrompt(basePrompt: "Base prompt", results: [result])

        #expect(prompt.contains("Base prompt"))
        #expect(prompt.contains("Tool: open"))
        #expect(prompt.contains("Status: success"))
        #expect(prompt.contains("answer normally and briefly"))
    }

    @Test("read_tabs parses with no arguments")
    func readTabsNoArgs() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"read_tabs"}"#))
        #expect(call.name == .readTabs)
        #expect(call.indices == nil)
        #expect(call.rawInput == "all")
    }

    @Test("read_tabs parses with explicit indices array")
    func readTabsIndices() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"read_tabs","indices":[1,3]}"#))
        #expect(call.name == .readTabs)
        #expect(call.indices == [1, 3])
        #expect(call.rawInput == "1,3")
    }

    @Test("create_artifact requires html, surfaces title in rawInput")
    func createArtifactParses() throws {
        let json = #"{"tool":"create_artifact","title":"Market Brief","html":"<!doctype html><body>hi</body>"}"#
        let call = try #require(NativeBrowserToolCall.parse(from: json))
        #expect(call.name == .createArtifact)
        #expect(call.title == "Market Brief")
        #expect(call.html?.contains("<body>hi</body>") == true)
        #expect(call.rawInput == "Market Brief")
    }

    @Test("create_artifact missing html is rejected")
    func createArtifactMissingHTML() {
        let json = #"{"tool":"create_artifact","title":"Empty"}"#
        #expect(NativeBrowserToolCall.parse(from: json) == nil)
    }

    @Test("web_control parses task argument")
    func webControlParsesTask() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"web_control","task":"Click the first result and summarize it."}"#))

        #expect(call.name == .webControl)
        #expect(call.task == "Click the first result and summarize it.")
        #expect(call.rawInput == "Click the first result and summarize it.")
    }

    @Test("mail_search parses raw query, mailbox, and max results")
    func mailSearchParsesArguments() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"mail_search","query":"from:alex newer_than:7d","mailbox":"inbox","max_results":5}"#))

        #expect(call.name == .mailSearch)
        #expect(call.query == "from:alex newer_than:7d")
        #expect(call.mailbox == "inbox")
        #expect(call.maxResults == 5)
        #expect(call.rawInput == "inbox from:alex newer_than:7d")
    }

    @Test("mail_search accepts a mailbox without a query")
    func mailSearchParsesMailboxOnly() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"mail_search","mailbox":"inbox","max_results":10}"#))

        #expect(call.name == .mailSearch)
        #expect(call.query == nil)
        #expect(call.mailbox == "inbox")
        #expect(call.rawInput == "inbox")
    }

    @Test("mail_search parses structured filters")
    func mailSearchParsesStructuredFilters() throws {
        let json = #"""
        {
            "tool": "mail_search",
            "mailbox": "inbox",
            "from": "alice@example.com",
            "subject": "invoice",
            "has_attachment": true,
            "unread_only": true,
            "newer_than": "7d",
            "after": "2025-01-01",
            "before": "2025-06-30",
            "format": "detailed"
        }
        """#
        let call = try #require(NativeBrowserToolCall.parse(from: json))

        #expect(call.name == .mailSearch)
        #expect(call.mailFrom == "alice@example.com")
        #expect(call.mailSubject == "invoice")
        #expect(call.mailHasAttachment == true)
        #expect(call.mailUnreadOnly == true)
        #expect(call.mailNewerThan == "7d")
        #expect(call.mailAfter == "2025-01-01")
        #expect(call.mailBefore == "2025-06-30")
        #expect(call.mailFormat == "detailed")
    }

    @Test("MailSearchOptions builds a valid Gmail query string")
    func mailSearchOptionsBuildQuery() {
        let options = MailSearchOptions(
            mailbox: .inbox,
            rawQuery: nil,
            from: "Alice Smith",
            to: nil,
            subject: "invoice",
            keyword: nil,
            label: nil,
            hasAttachment: true,
            unreadOnly: true,
            starredOnly: nil,
            newerThan: "7d",
            olderThan: nil,
            after: "2025-01-01",
            before: nil,
            maxResults: 20,
            format: .compact
        )

        let query = options.gmailQueryString()
        #expect(query.contains("from:\"Alice Smith\""))
        #expect(query.contains("subject:invoice"))
        #expect(query.contains("has:attachment"))
        #expect(query.contains("is:unread"))
        #expect(query.contains("newer_than:7d"))
        #expect(query.contains("after:2025/01/01"))
    }

    @Test("MailSearchOptions rejects malformed dates and durations")
    func mailSearchOptionsRejectsMalformed() {
        let options = MailSearchOptions(
            mailbox: nil,
            rawQuery: nil,
            from: nil,
            to: nil,
            subject: nil,
            keyword: "hello",
            label: nil,
            hasAttachment: nil,
            unreadOnly: nil,
            starredOnly: nil,
            newerThan: "two weeks",
            olderThan: nil,
            after: "January 1",
            before: nil,
            maxResults: 10,
            format: .compact
        )

        let query = options.gmailQueryString()
        #expect(query == "hello")
        #expect(options.validationError?.contains("newer_than") == true)
        #expect(options.validationError?.contains("after") == true)
    }

    @Test("MailSearchOptions ignores inactive false boolean filters")
    func mailSearchOptionsIgnoreFalseBooleans() {
        let options = MailSearchOptions(
            mailbox: nil,
            rawQuery: nil,
            from: nil,
            to: nil,
            subject: nil,
            keyword: nil,
            label: nil,
            hasAttachment: false,
            unreadOnly: false,
            starredOnly: false,
            newerThan: nil,
            olderThan: nil,
            after: nil,
            before: nil,
            maxResults: 10,
            format: .compact
        )

        #expect(!options.hasAnyFilter)
        #expect(options.gmailQueryString().isEmpty)
    }

    @Test("mail_read_thread parses message id")
    func mailReadThreadParsesMessageID() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"mail_read_thread","message_id":"msg-123"}"#))

        #expect(call.name == .mailReadThread)
        #expect(call.mailIdentifier == MailToolMessageIdentifier(kind: .message, value: "msg-123"))
        #expect(call.rawInput == "message:msg-123")
    }

    @Test("mail_read_thread parses batch identifiers and body options")
    func mailReadThreadParsesBatch() throws {
        let json = #"""
        {
            "tool": "mail_read_thread",
            "message_ids": ["msg:msg-a", "msg-b"],
            "thread_ids": ["thr-c", "thread:thr-d"],
            "include_body": false,
            "max_body_chars": 500
        }
        """#
        let call = try #require(NativeBrowserToolCall.parse(from: json))

        #expect(call.name == .mailReadThread)
        let identifiers = call.mailIdentifiers
        #expect(identifiers.count == 4)
        #expect(identifiers[0] == MailToolMessageIdentifier(kind: .message, value: "msg-a"))
        #expect(identifiers[1] == MailToolMessageIdentifier(kind: .message, value: "msg-b"))
        #expect(identifiers[2] == MailToolMessageIdentifier(kind: .thread, value: "thr-c"))
        #expect(identifiers[3] == MailToolMessageIdentifier(kind: .thread, value: "thr-d"))
        #expect(call.mailIncludeBody == false)
        #expect(call.mailMaxBodyChars == 500)
    }

    @Test("mail_draft_reply parses thread id and body")
    func mailDraftReplyParsesBody() throws {
        let call = try #require(NativeBrowserToolCall.parse(from: #"{"tool":"mail_draft_reply","thread_id":"thr-123","body":"Thanks, that works."}"#))

        #expect(call.name == .mailDraftReply)
        #expect(call.mailIdentifier == MailToolMessageIdentifier(kind: .thread, value: "thr-123"))
        #expect(call.body == "Thanks, that works.")
    }

    @Test("Direct mail slash commands parse")
    func directMailSlashCommandsParse() throws {
        let search = try #require(DirectNativeToolCommand.parse("/mail_search inbox from:alex"))
        let inbox = try #require(DirectNativeToolCommand.parse("/mail_search inbox"))
        let read = try #require(DirectNativeToolCommand.parse("/mail_read_thread thread:thr-123"))
        let draft = try #require(DirectNativeToolCommand.parse("/mail_draft_reply msg-123 | Sounds good."))

        #expect(search.name == .mailSearch)
        #expect(search.mailbox == "inbox")
        #expect(search.query == "from:alex")
        #expect(inbox.name == .mailSearch)
        #expect(inbox.mailbox == "inbox")
        #expect(inbox.query == "")
        #expect(read.mailIdentifier == MailToolMessageIdentifier(kind: .thread, value: "thr-123"))
        #expect(draft.mailIdentifier == MailToolMessageIdentifier(kind: .message, value: "msg-123"))
        #expect(draft.body == "Sounds good.")
    }

    @Test("Natural inbox requests route directly to mail search")
    func naturalInboxRequestsRouteToMailSearch() throws {
        let broad = try #require(DirectNativeToolCommand.parse("what mails do I have?"))
        let inbox = try #require(DirectNativeToolCommand.parse("in my inbox"))
        let unread = try #require(DirectNativeToolCommand.parse("show unread emails"))
        let sender = try #require(DirectNativeToolCommand.parse("do I have email from Alex?"))

        #expect(broad.name == .mailSearch)
        #expect(broad.mailbox == "inbox")
        #expect(broad.query == "")
        #expect(inbox.name == .mailSearch)
        #expect(inbox.mailbox == "inbox")
        #expect(unread.name == .mailSearch)
        #expect(unread.mailbox == "inbox")
        #expect(unread.query == "is:unread")
        #expect(sender.name == .mailSearch)
        #expect(sender.mailbox == "inbox")
        #expect(sender.query == "from:alex")
    }

    @Test("Web control agent command parses actions")
    func webControlAgentCommandParsesActions() throws {
        let command = try #require(WebControlAgentCommand.parse(from: #"{"action":"type","id":"wca-abc","text":"wordle","clear":true}"#))

        #expect(command.action == .type)
        #expect(command.id == "wca-abc")
        #expect(command.text == "wordle")
        #expect(command.clear)
    }

    @MainActor
    @Test("web_control invokes isolated runner closure")
    func webControlInvokesRunner() async {
        var receivedTask = ""
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") },
            runWebControl: { task in
                receivedTask = task
                return WebControlAgentOutcome(succeeded: true, summary: "Done.", stepCount: 3)
            }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(name: .webControl, task: "Play Wordle")
        )

        #expect(result.succeeded)
        #expect(receivedTask == "Play Wordle")
        #expect(result.content.contains("Steps: 3"))
        #expect(result.invocation.tool == "web_control")
    }

    @MainActor
    @Test("mail_search opens Gmail overlay and formats results")
    func mailSearchInvokesMailBridge() async {
        var openedMail = false
        var receivedOptions: MailSearchOptions?
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            openMailIntegration: {
                openedMail = true
            },
            searchMail: { options in
                receivedOptions = options
                return [
                    GmailMessageSummary(
                        id: "msg-123",
                        threadId: "thr-123",
                        snippet: "See you Thursday",
                        subject: "Planning",
                        fromName: "Alex",
                        fromAddress: "alex@example.com",
                        date: Date(timeIntervalSince1970: 0),
                        unread: true,
                        starred: false,
                        labelIDs: ["INBOX", "UNREAD"]
                    )
                ]
            },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(name: .mailSearch, mailbox: "inbox")
        )

        #expect(openedMail)
        #expect(receivedOptions?.mailbox == .inbox)
        #expect(receivedOptions?.gmailQueryString() == "")
        #expect(result.succeeded)
        #expect(result.content.contains("msg:msg-123"))
        #expect(result.content.contains("Planning"))
        #expect(result.content.contains("Mailbox: Inbox"))
        #expect(result.invocation.tool == "mail_search")
    }

    @MainActor
    @Test("mail_search rejects empty filter set with helpful message")
    func mailSearchRejectsEmptyFilters() async {
        var openedMail = false
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            openMailIntegration: { openedMail = true },
            searchMail: { _ in
                Issue.record("searchMail should not be invoked when no filter is supplied")
                return []
            },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )

        let result = await executor.execute(NativeBrowserToolCall(name: .mailSearch))

        #expect(!result.succeeded)
        #expect(openedMail)
        #expect(result.content.contains("at least one filter"))
    }

    @MainActor
    @Test("mail_search rejects invalid structured filters before searching")
    func mailSearchRejectsInvalidFilters() async {
        var searched = false
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            searchMail: { _ in
                searched = true
                return []
            },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(name: .mailSearch, mailNewerThan: "two weeks", mailAfter: "2025-02-31")
        )

        #expect(!result.succeeded)
        #expect(!searched)
        #expect(result.content.contains("invalid filters"))
        #expect(result.content.contains("newer_than"))
        #expect(result.content.contains("after"))
    }

    @MainActor
    @Test("mail_read_thread fans out across batched identifiers")
    func mailReadThreadBatch() async {
        var receivedOptions: MailReadOptions?
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            openMailIntegration: {},
            readMail: { options in
                receivedOptions = options
                return options.identifiers.map { identifier in
                    [
                        GmailMessage(
                            id: identifier.value,
                            threadId: "thr-\(identifier.value)",
                            subject: "Subject \(identifier.value)",
                            fromName: "Sender",
                            fromAddress: "sender@example.com",
                            to: "me@example.com",
                            cc: nil,
                            date: Date(timeIntervalSince1970: 0),
                            snippet: "snippet",
                            plainBody: String(repeating: "x", count: 3_000),
                            htmlBody: nil,
                            labelIDs: [],
                            unread: false
                        )
                    ]
                }
            },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(
                name: .mailReadThread,
                messageIDs: ["msg-a", "msg-b"],
                mailIncludeBody: true,
                mailMaxBodyChars: 200
            )
        )

        #expect(result.succeeded)
        #expect(receivedOptions?.identifiers.count == 2)
        #expect(receivedOptions?.maxBodyChars == 200)
        #expect(result.content.contains("Read 2 threads."))
        #expect(result.content.contains("msg:msg-a"))
        #expect(result.content.contains("msg:msg-b"))
        #expect(result.content.contains("body truncated at 200 chars"))
    }

    @MainActor
    @Test("mail_read_thread headers-only skips body block")
    func mailReadThreadHeadersOnly() async {
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            openMailIntegration: {},
            readMail: { _ in
                [[
                    GmailMessage(
                        id: "msg-x",
                        threadId: "thr-x",
                        subject: "Subject X",
                        fromName: "Sender",
                        fromAddress: "sender@example.com",
                        to: "me@example.com",
                        cc: nil,
                        date: Date(timeIntervalSince1970: 0),
                        snippet: "snip",
                        plainBody: "Real body content that we don't want to see.",
                        htmlBody: nil,
                        labelIDs: [],
                        unread: false
                    )
                ]]
            },
            saveAndOpenArtifact: { _, _ in URL(fileURLWithPath: "/tmp/unused.html") }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(
                name: .mailReadThread,
                messageID: "msg-x",
                mailIncludeBody: false
            )
        )

        #expect(result.succeeded)
        #expect(result.content.contains("headers only"))
        #expect(!result.content.contains("Real body content"))
    }

    @MainActor
    @Test("create_artifact carries the saved file URL into the tool result and invocation")
    func createArtifactPropagatesURL() async {
        let savedURL = URL(fileURLWithPath: "/tmp/2026-05-10_12-00-00_market-brief.html")
        let executor = NativeBrowserToolExecutor(
            openURL: { _ in },
            readTabsContent: { _ in "" },
            readHighlightsContent: { _ in "" },
            smartReadContent: { "" },
            saveAndOpenArtifact: { _, _ in savedURL }
        )

        let result = await executor.execute(
            NativeBrowserToolCall(
                name: .createArtifact,
                title: "Market Brief",
                html: "<!doctype html><body>hi</body>"
            )
        )

        #expect(result.succeeded)
        #expect(result.artifactURL == savedURL)
        #expect(result.invocation.artifactURL == savedURL)
    }

    @Test("Detects a leading tool call when followed by another tool call and prose")
    func leadingToolCallWithChainedFollowup() throws {
        // Reproduces the bug from the screenshot: model emits read_tabs JSON,
        // then create_artifact JSON, then a prose summary — all in one
        // response. Without leading-JSON detection the whole reply was shown
        // as chat text and no tool ran.
        let response = #"""
        {"tool":"read_tabs","indices":[1]}

        {"tool":"create_artifact","title":"Georgia Tech","html":"<!doctype html><body>hi</body>"}

        Here's the artifact — a full editorial brief on Georgia Tech.
        """#

        let call = try #require(NativeBrowserToolCall.parse(from: response))
        // Must pick the FIRST tool (read_tabs), not the second, so the model
        // gets the tab content before being asked to generate the artifact.
        #expect(call.name == .readTabs)
        #expect(call.indices == [1])
    }

    @Test("Detects a leading tool call when followed by trailing prose")
    func leadingToolCallWithTrailingProse() throws {
        let response = #"""
        {"tool":"open","url":"https://example.com"}

        Opening that for you now.
        """#

        let call = try #require(NativeBrowserToolCall.parse(from: response))
        #expect(call.name == .open)
        #expect(call.url == "https://example.com")
    }

    @Test("Picks the leading tool call when two tool calls sit back-to-back")
    func leadingToolCallBeatsTrailingToolCall() throws {
        // No prose at all — just two tool calls. We want the FIRST one to run
        // first (read_tabs feeds the model the data it needs before the next
        // turn's create_artifact).
        let response = #"""
        {"tool":"read_tabs"}
        {"tool":"create_artifact","title":"x","html":"<html></html>"}
        """#

        let call = try #require(NativeBrowserToolCall.parse(from: response))
        #expect(call.name == .readTabs)
    }

    @Test("ArtifactStore slugs titles for safe filenames")
    func artifactSlug() {
        #expect(ArtifactStore.slug(from: "Market Overview!") == "market-overview")
        #expect(ArtifactStore.slug(from: "  hello   world  ") == "hello-world")
        #expect(ArtifactStore.slug(from: "***") == "artifact")
        #expect(ArtifactStore.slug(from: "") == "artifact")
        let long = String(repeating: "a", count: 200)
        #expect(ArtifactStore.slug(from: long).count <= 60)
    }

    @Test("BrowserTab.artifactAlias renders friendly URL-bar labels for artifacts")
    func artifactAlias() {
        let stamped = URL(fileURLWithPath: "/Users/test/.thebrowser/web_artifacts/2026-05-10_23-54-50_georgia-institute-of-technology-school.html")
        #expect(BrowserTab.artifactAlias(for: stamped) == "Georgia Institute Of Technology School")

        let singleWord = URL(fileURLWithPath: "/tmp/2026-01-01_00-00-00_overview.html")
        #expect(BrowserTab.artifactAlias(for: singleWord) == "Overview")

        let noTimestamp = URL(fileURLWithPath: "/tmp/loose-file.html")
        #expect(BrowserTab.artifactAlias(for: noTimestamp) == "Loose File")
    }

    @MainActor
    @Test("BrowserTab.editableAddress reveals the raw URL while displayAddress masks artifacts")
    func editableAddressMasksArtifacts() {
        let tab = BrowserTab()

        // Home tab: both empty.
        #expect(tab.displayAddress == "")
        #expect(tab.editableAddress == "")

        // Artifact: displayAddress shows the friendly alias, editableAddress
        // exposes the file URL so the user can copy or edit it.
        let artifactURL = ArtifactStore.rootURL.appendingPathComponent("2026-05-10_12-00-00_market-brief.html")
        tab.isHome = false
        tab.url = artifactURL

        #expect(tab.isArtifact)
        #expect(tab.displayAddress == "Market Brief")
        #expect(tab.editableAddress == artifactURL.absoluteString)

        // Regular URL: both return the absolute URL.
        let regularURL = URL(string: "https://example.com/")!
        tab.url = regularURL

        #expect(!tab.isArtifact)
        #expect(tab.displayAddress == regularURL.absoluteString)
        #expect(tab.editableAddress == regularURL.absoluteString)
    }
}
