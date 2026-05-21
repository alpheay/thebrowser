import Foundation

enum NativeBrowserToolName: String, Equatable, Sendable {
    case open
    case search
    case fetch
    case readTabs = "read_tabs"
    case readHighlights = "read_highlights"
    case readSmartRead = "read_smart_read"
    case mailSearch = "mail_search"
    case mailReadThread = "mail_read_thread"
    case mailDraftReply = "mail_draft_reply"
    case createArtifact = "create_artifact"
    case webControl = "web_control"
}

struct MailToolMessageIdentifier: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case message
        case thread
    }

    var kind: Kind
    var value: String

    var displayValue: String {
        switch kind {
        case .message: return "message:\(value)"
        case .thread: return "thread:\(value)"
        }
    }
}

struct NativeBrowserToolCall: Equatable, Sendable {
    var name: NativeBrowserToolName
    var url: String? = nil
    var query: String? = nil
    var task: String? = nil
    var title: String? = nil
    var html: String? = nil
    var indices: [Int]? = nil
    var mailbox: String? = nil
    var messageID: String? = nil
    var threadID: String? = nil
    var body: String? = nil
    var maxResults: Int? = nil

    static func parse(from text: String) -> NativeBrowserToolCall? {
        for candidate in jsonObjectCandidates(in: text) {
            if let call = parse(json: candidate) {
                return call
            }
        }
        return nil
    }

    var rawInput: String {
        switch name {
        case .open, .fetch:
            return url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .search:
            return query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .webControl:
            return task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .readTabs, .readHighlights:
            if let indices, !indices.isEmpty {
                return indices.map(String.init).joined(separator: ",")
            }
            return "all"
        case .readSmartRead:
            return "summary"
        case .mailSearch:
            let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let mailbox = mailbox?.trimmingCharacters(in: .whitespacesAndNewlines), !mailbox.isEmpty else {
                return trimmedQuery
            }
            guard !trimmedQuery.isEmpty else {
                return mailbox
            }
            return "\(mailbox): \(trimmedQuery)"
        case .mailReadThread:
            return mailIdentifier?.displayValue ?? ""
        case .mailDraftReply:
            let preview = body?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let capped = preview.count > 40 ? String(preview.prefix(40)) + "…" : preview
            return [mailIdentifier?.displayValue ?? "", capped]
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
        case .createArtifact:
            return title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "artifact"
        }
    }

    var mailIdentifier: MailToolMessageIdentifier? {
        if let id = messageID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return MailToolMessageIdentifier(kind: .message, value: id)
        }
        if let id = threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return MailToolMessageIdentifier(kind: .thread, value: id)
        }
        return nil
    }

    private static func parse(json: String) -> NativeBrowserToolCall? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let arguments = dictionary["arguments"] as? [String: Any] ?? [:]
        let rawName = (dictionary["tool"] as? String)
            ?? (dictionary["name"] as? String)
            ?? (dictionary["action"] as? String)

        guard
            let rawName,
            let name = NativeBrowserToolName(rawValue: rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return nil
        }

        let url = stringValue(named: "url", in: dictionary, arguments: arguments)
            ?? stringValue(named: "target", in: dictionary, arguments: arguments)
        let query = stringValue(named: "query", in: dictionary, arguments: arguments)
            ?? stringValue(named: "q", in: dictionary, arguments: arguments)
        let task = stringValue(named: "task", in: dictionary, arguments: arguments)
            ?? stringValue(named: "goal", in: dictionary, arguments: arguments)
            ?? stringValue(named: "request", in: dictionary, arguments: arguments)
            ?? stringValue(named: "instruction", in: dictionary, arguments: arguments)
        let title = stringValue(named: "title", in: dictionary, arguments: arguments)
        let html = stringValue(named: "html", in: dictionary, arguments: arguments)
        let indices = intArrayValue(named: "indices", in: dictionary, arguments: arguments)
            ?? intArrayValue(named: "tabs", in: dictionary, arguments: arguments)
            ?? intArrayValue(named: "highlights", in: dictionary, arguments: arguments)
        let mailbox = stringValue(named: "mailbox", in: dictionary, arguments: arguments)
            ?? stringValue(named: "label", in: dictionary, arguments: arguments)
        let messageID = stringValue(named: "message_id", in: dictionary, arguments: arguments)
            ?? stringValue(named: "messageId", in: dictionary, arguments: arguments)
            ?? stringValue(named: "message", in: dictionary, arguments: arguments)
            ?? (name == .mailReadThread || name == .mailDraftReply ? stringValue(named: "id", in: dictionary, arguments: arguments) : nil)
        let threadID = stringValue(named: "thread_id", in: dictionary, arguments: arguments)
            ?? stringValue(named: "threadId", in: dictionary, arguments: arguments)
            ?? stringValue(named: "thread", in: dictionary, arguments: arguments)
        let body = stringValue(named: "body", in: dictionary, arguments: arguments)
            ?? stringValue(named: "draft", in: dictionary, arguments: arguments)
            ?? stringValue(named: "reply", in: dictionary, arguments: arguments)
            ?? stringValue(named: "text", in: dictionary, arguments: arguments)
            ?? stringValue(named: "content", in: dictionary, arguments: arguments)
        let maxResults = intValue(named: "max_results", in: dictionary, arguments: arguments)
            ?? intValue(named: "maxResults", in: dictionary, arguments: arguments)
            ?? intValue(named: "limit", in: dictionary, arguments: arguments)

        let call = NativeBrowserToolCall(
            name: name,
            url: url,
            query: query,
            task: task,
            title: title,
            html: html,
            indices: indices,
            mailbox: mailbox,
            messageID: messageID,
            threadID: threadID,
            body: body,
            maxResults: maxResults
        )

        switch name {
        case .open, .fetch, .search, .webControl:
            return call.rawInput.isEmpty ? nil : call
        case .readTabs, .readHighlights, .readSmartRead:
            return call
        case .mailSearch:
            return call.rawInput.isEmpty ? nil : call
        case .mailReadThread:
            return call.mailIdentifier == nil ? nil : call
        case .mailDraftReply:
            return call.mailIdentifier == nil || (body?.isEmpty ?? true) ? nil : call
        case .createArtifact:
            return (html?.isEmpty == false) ? call : nil
        }
    }

    private static func stringValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> String? {
        let raw = (dictionary[key] as? String) ?? (arguments[key] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func intArrayValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> [Int]? {
        let raw = dictionary[key] ?? arguments[key]
        guard let array = raw as? [Any] else { return nil }
        let ints: [Int] = array.compactMap { item in
            if let int = item as? Int { return int }
            if let number = item as? NSNumber { return number.intValue }
            if let string = item as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }
        return ints.isEmpty ? nil : ints
    }

    private static func intValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> Int? {
        let raw = dictionary[key] ?? arguments[key]
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            candidates.append(trimmed)
        }

        // Leading-JSON candidate: the first balanced `{…}` at position 0 of
        // the response. Catches the case where the model emits a tool call
        // followed by ANYTHING (more tool calls, a prose summary, both).
        // Without this, a response like
        //   {"tool":"read_tabs"}\n\n{"tool":"create_artifact",...}\n\nHere's the artifact…
        // would slip past every other detector — the whole-text check fails
        // (multiple objects), the trailing check fails (ends with prose),
        // and there's no fence. Picking the FIRST tool call also gives the
        // right execution order: read_tabs runs before create_artifact in
        // the next turn's continuation.
        if let leading = leadingJSONObject(in: trimmed) {
            candidates.append(leading)
        }

        // Fenced tool-call block. Anchors are intentionally absent so a fence
        // can sit after prose — models often introduce the call with a
        // sentence before the fence.
        let fencePattern = #"```(?:browser_tool|json)?\s*(\{[\s\S]*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: trimmed) else { continue }
                candidates.append(String(trimmed[range]))
            }
        }

        // Trailing-JSON fallback: a balanced `{…}` whose closing brace is the
        // final non-whitespace character of the response counts as a tool
        // call. This catches the common case where the model writes a
        // sentence like "Let me open that for you." and then emits the JSON
        // on its own line. Examples embedded mid-prose are skipped because
        // the response won't end with `}`.
        if let trailing = trailingJSONObject(in: trimmed) {
            candidates.append(trailing)
        }

        return candidates.removingDuplicates()
    }

    /// Returns the substring of a complete top-level JSON object that starts
    /// the input, or `nil` if the input doesn't start with one or the JSON is
    /// followed by same-line prose. Walks forward tracking brace depth and
    /// JSON string literals so braces inside quoted text don't confuse the
    /// balance.
    ///
    /// To distinguish a real tool call ("model emitted JSON, then a new
    /// paragraph") from a chatty mid-sentence reference ("model wrote
    /// `{tool:"open",...}` — let me know if that's right"), the JSON must be
    /// the entire response *or* be followed by a newline before any further
    /// non-whitespace content. Same-line continuation reads as prose, not a
    /// tool call.
    private static func leadingJSONObject(in text: String) -> String? {
        guard text.hasPrefix("{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(after: index)
                    let candidate = String(text[text.startIndex..<endIndex])
                    let remainder = text[endIndex..<text.endIndex]
                    return remainderIsParagraphBreakOrEmpty(remainder) ? candidate : nil
                }
                if depth < 0 {
                    return nil
                }
            }
        }
        return nil
    }

    /// True when `remainder` is empty, all whitespace, or contains a newline
    /// before its first non-whitespace character. False when prose continues
    /// on the same line as the preceding token (which signals conversation,
    /// not a structured tool call).
    private static func remainderIsParagraphBreakOrEmpty(_ remainder: Substring) -> Bool {
        for character in remainder {
            if character.isNewline {
                return true
            }
            if !character.isWhitespace {
                return false
            }
        }
        return true
    }

    /// Returns the substring of a complete top-level JSON object that ends
    /// the input, or `nil` if the input does not finish with one. Walks
    /// forward tracking brace depth and JSON string literals so braces
    /// inside quoted text don't confuse the balance.
    private static func trailingJSONObject(in text: String) -> String? {
        guard text.hasSuffix("}") else { return nil }

        var depth = 0
        var startIndex: String.Index? = nil
        var inString = false
        var escaped = false
        var lastCandidate: Range<String.Index>? = nil

        for index in text.indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    lastCandidate = start..<text.index(after: index)
                    startIndex = nil
                } else if depth < 0 {
                    return nil
                }
            }
        }

        guard let range = lastCandidate, range.upperBound == text.endIndex else {
            return nil
        }
        return String(text[range])
    }
}

struct NativeBrowserToolResult: Equatable, Sendable {
    var call: NativeBrowserToolCall
    var succeeded: Bool
    var content: String
    var artifactURL: URL? = nil

    var promptText: String {
        """
        Tool: \(call.name.rawValue)
        Status: \(succeeded ? "success" : "failed")
        \(content)
        """
    }

    /// The compact, UI-facing record of this tool call. Strips the prompt
    /// transcript and just keeps the name, raw input, and outcome — enough
    /// to render in the chat tool-chain row.
    var invocation: ChatMessage.ToolInvocation {
        ChatMessage.ToolInvocation(
            tool: call.name.rawValue,
            input: call.rawInput,
            succeeded: succeeded,
            artifactURL: artifactURL
        )
    }
}

struct NativeBrowserToolExecutor {
    var openURL: @MainActor (URL) -> Void
    var readTabsContent: @MainActor ([Int]?) async -> String
    /// Resolves a `read_highlights` call against the chat session's
    /// accumulated highlights. Receives 1-based global indices (or nil to
    /// dump them all) and returns a formatted text block. Implemented in
    /// the chat layer so the executor itself doesn't need to know about
    /// ChatViewModel.
    var readHighlightsContent: @MainActor ([Int]?) async -> String
    /// Resolves a `read_smart_read` call against the current Smart Read
    /// panel state. Returns the formatted summary (TL;DR + key points +
    /// metadata) when one is loaded, or a status message when the panel is
    /// idle, loading, or in a failed state.
    var smartReadContent: @MainActor () async -> String
    var openMailIntegration: @MainActor () -> Void
    var searchMail: @MainActor (_ query: String, _ mailbox: GmailMailbox?, _ maxResults: Int) async throws -> [GmailMessageSummary]
    var readMailThread: @MainActor (_ identifier: MailToolMessageIdentifier) async throws -> [GmailMessage]
    var draftMailReply: @MainActor (_ identifier: MailToolMessageIdentifier, _ body: String) async throws -> GmailMessage
    var saveAndOpenArtifact: @MainActor (_ title: String, _ html: String) async throws -> URL
    var runWebControl: @MainActor (_ task: String) async -> WebControlAgentOutcome

    init(
        openURL: @escaping @MainActor (URL) -> Void,
        readTabsContent: @escaping @MainActor ([Int]?) async -> String,
        readHighlightsContent: @escaping @MainActor ([Int]?) async -> String,
        smartReadContent: @escaping @MainActor () async -> String,
        openMailIntegration: @escaping @MainActor () -> Void = {},
        searchMail: @escaping @MainActor (_ query: String, _ mailbox: GmailMailbox?, _ maxResults: Int) async throws -> [GmailMessageSummary] = { _, _, _ in
            throw NativeMailToolError.unavailable
        },
        readMailThread: @escaping @MainActor (_ identifier: MailToolMessageIdentifier) async throws -> [GmailMessage] = { _ in
            throw NativeMailToolError.unavailable
        },
        draftMailReply: @escaping @MainActor (_ identifier: MailToolMessageIdentifier, _ body: String) async throws -> GmailMessage = { _, _ in
            throw NativeMailToolError.unavailable
        },
        saveAndOpenArtifact: @escaping @MainActor (_ title: String, _ html: String) async throws -> URL,
        runWebControl: @escaping @MainActor (_ task: String) async -> WebControlAgentOutcome = { _ in
            WebControlAgentOutcome(
                succeeded: false,
                summary: "Web control is not configured in this browser surface.",
                stepCount: 0
            )
        }
    ) {
        self.openURL = openURL
        self.readTabsContent = readTabsContent
        self.readHighlightsContent = readHighlightsContent
        self.smartReadContent = smartReadContent
        self.openMailIntegration = openMailIntegration
        self.searchMail = searchMail
        self.readMailThread = readMailThread
        self.draftMailReply = draftMailReply
        self.saveAndOpenArtifact = saveAndOpenArtifact
        self.runWebControl = runWebControl
    }

    func execute(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        switch call.name {
        case .open:
            return await open(call)
        case .search:
            return await search(call)
        case .fetch:
            return await fetch(call)
        case .readTabs:
            return await readTabs(call)
        case .readHighlights:
            return await readHighlights(call)
        case .readSmartRead:
            return await readSmartRead(call)
        case .mailSearch:
            return await mailSearch(call)
        case .mailReadThread:
            return await mailReadThread(call)
        case .mailDraftReply:
            return await mailDraftReply(call)
        case .createArtifact:
            return await createArtifact(call)
        case .webControl:
            return await webControl(call)
        }
    }
}

enum NativeBrowserToolPrompt {
    static let instructions = """
    Native browser tools available in this app:
    - open: navigates the current tab to a URL. Use for requests like "open youtube".
    - search: runs the app's native web search and returns result titles, URLs, and snippets.
    - fetch: downloads a URL and returns readable page text.
    - read_tabs: returns the visible text of the user's currently open tabs. Use this when the user asks about, summarizes across, or wants to act on the tabs they already have open. Pass `indices` (1-based) to read specific tabs, or omit it to read all of them.
    - read_highlights: returns the full text of highlights (page passages the user clipped via the Ask widget) attached earlier in the conversation. The prompt lists prior highlights by their 1-based global index with source + preview only; use this tool to fetch the full text of one or more of them when the user references "the highlight", "what I sent earlier", a specific quoted phrase, etc. Pass `indices` (1-based) to read specific highlights, or omit it to read all of them. The CURRENT turn's highlights are already inlined in the prompt — only call this tool for highlights from PRIOR turns.
    - read_smart_read: returns the Smart Read summary currently displayed in the chat sidebar (TL;DR sentence, numbered key points, read time, word count, page title, page URL). Use this whenever the user references "the smart read", "the summary", "what did smart read say", or asks for any details from the summary panel. The prompt notes when a Smart Read is active — only call this tool while one is shown. Takes no arguments.
    - mail_search: searches or lists the connected Gmail account and opens the Gmail overlay to the results. Use when the user asks you to find, triage, summarize, list, show, or act on mail. For broad requests like "what mail do I have?", "show my inbox", "what's in my inbox", or "in my inbox", call mail_search with `mailbox:"inbox"` and omit `query`. Pass `query` only when the user gives search constraints, using Gmail search syntax. Optional `mailbox` is one of inbox, starred, sent, drafts, all. Optional `max_results` is 1-20.
    - mail_read_thread: reads a Gmail thread and opens the Gmail overlay to the message. Pass either `message_id` from mail_search results or `thread_id`.
    - mail_draft_reply: opens the Gmail overlay composer with a reply draft. Pass either `message_id` or `thread_id`, plus `body` containing the exact reply draft text. This does not send mail; the user reviews and sends.
    - create_artifact: saves a fully self-contained HTML document under ~/.thebrowser/web_artifacts/ and opens it in a new tab. Use this when the user asks for an "artifact", "document", "report", "dashboard", "summary", or anything similar that should be rendered as a standalone page.
    - web_control: delegates a bounded task to a separate web-control agent and live-page harness that can click, type, press keys, scroll, wait, navigate, and inspect the current WKWebView without adding its step-by-step context to this chat. Use it when the user asks you to interact with a live site or web app on their behalf: click links/buttons, fill fields/forms, operate menus, submit searches, complete a workflow, or play a browser game such as Wordle. Pass a concise `task` string describing the user's goal and any constraints. The harness will show an "Agent is Working" overlay while it controls the page.

    To use a tool, reply with only one JSON object and no prose:
    {"tool":"open","url":"https://example.com"}
    {"tool":"search","query":"weather in New York"}
    {"tool":"fetch","url":"https://example.com/article"}
    {"tool":"read_tabs"}
    {"tool":"read_tabs","indices":[1,3]}
    {"tool":"read_highlights","indices":[2]}
    {"tool":"read_smart_read"}
    {"tool":"mail_search","query":"from:alex newer_than:30d","mailbox":"inbox","max_results":10}
    {"tool":"mail_search","mailbox":"inbox","max_results":10}
    {"tool":"mail_read_thread","message_id":"message-id-from-search"}
    {"tool":"mail_draft_reply","message_id":"message-id-from-search","body":"Thanks — I can do Thursday at 2 PM."}
    {"tool":"create_artifact","title":"Market Overview","html":"<!doctype html><html>…</html>"}
    {"tool":"web_control","task":"On the current page, play one game of Wordle and report the outcome."}

    CRITICAL tool-call rules — follow these or the dispatcher will treat your tool call as plain chat text and the action will silently fail:
    1. EXACTLY ONE tool call per response. Never emit two JSON objects in the same response. If you need read_tabs THEN create_artifact, emit only the read_tabs call now and wait for the result before emitting create_artifact in your next turn.
    2. ZERO prose in a tool-call response. No leading sentence, no trailing summary, no explanation, no markdown headings. The entire response must be the bare JSON object.
    3. The response MUST start with `{` and END with `}`. Anything else is treated as a normal chat answer.
    4. When you need to describe what a tool does to the user, use plain English. Do not paste JSON examples into chat answers.

    Use a tool only when it helps the user's request. If the user asks you to open or navigate to a site, use the open tool instead of saying you will do it. Use web_control for live interactions that require clicking, typing, pressing keys, scrolling, or reading dynamic page state. If no tool is needed, answer normally. Never say a browser action happened unless a native tool result in this conversation says it succeeded. Do not claim you managed bookmarks/history/settings or inspected hidden page state.

    create_artifact design language — every artifact MUST follow this style:
    - Background #0a0a0a, text in pure white and warm grays only. NO other colors. No blue links, no green success badges, no red warnings.
    - Inter font loaded from https://rsms.me/inter/inter.css. Display headings: weight 200–300, generous letter-spacing (-0.02em), large (40–72px). Body: weight 400, 15–17px, line-height 1.6.
    - Editorial layout: max-width ~1100px, centered, generous padding. Section dividers as 1px lines at white @ 8% opacity. Plenty of whitespace between blocks.
    - For data: use Chart.js v4 from https://cdn.jsdelivr.net/npm/chart.js. Configure all charts in monochrome — strokes/fills in white at varying opacities (0.95, 0.6, 0.3), gridlines in white @ 6%, no legend backgrounds. Disable Chart.js color defaults explicitly.
    - Animations: subtle entrance fades on load (opacity + 8px translate, 600ms ease-out, staggered). Slow shimmer or breathing pulse on hero elements is OK. NO bounce, NO playful motion, NO bright color transitions.
    - Output a SINGLE complete HTML document with inline <style> and <script>. Include <!doctype html>, <meta charset>, <meta viewport>. The `html` argument must contain the full document — not a snippet.
    - Be substantive: synthesize, compare, and visualize. Don't just dump bullet lists. The artifact should feel like a thoughtful editorial brief, not a meeting notes export.
    """

    static func continuationPrompt(basePrompt: String, results: [NativeBrowserToolResult]) -> String {
        let transcript = results.enumerated().map { index, result in
            """
            Native browser tool result \(index + 1):
            \(result.promptText)
            """
        }.joined(separator: "\n\n")

        return """
        \(basePrompt)

        \(transcript)

        Use the native browser tool result to continue the same user request. If one more native browser tool is required, reply with only the next JSON tool call. Otherwise, answer normally and briefly. Do not claim any browser action succeeded unless the tool result says success.
        """
    }
}

enum NativeBrowserToolURL {
    static func url(from rawValue: String) -> URL? {
        guard let url = AddressResolver.url(for: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            return nil
        }
        return url
    }
}

enum NativeMailToolError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Mail tools are not configured in this browser surface."
        }
    }
}

enum DirectNativeToolCommand {
    static let helpText = """
    Mail commands:
    /mail_search [inbox|starred|sent|drafts|all] [Gmail search query]
    /mail_read_thread [message:<id>|thread:<id>|<message-id>]
    /mail_draft_reply [message:<id>|thread:<id>|<message-id>] | <reply body>
    """

    static func parse(_ text: String) -> NativeBrowserToolCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return inferredMailSearch(from: trimmed) }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = parts.first?.lowercased() else { return nil }
        let remainder = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch command {
        case "/mail_search":
            return parseMailSearch(remainder)
        case "/mail_read_thread":
            return parseMailReadThread(remainder)
        case "/mail_draft_reply":
            return parseMailDraftReply(remainder)
        default:
            return nil
        }
    }

    private static func parseMailSearch(_ text: String) -> NativeBrowserToolCall? {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var mailbox: String? = query.isEmpty ? GmailMailbox.inbox.rawValue : nil
        if let first = query.split(maxSplits: 1, whereSeparator: \.isWhitespace).first {
            let candidate = String(first).lowercased()
            if GmailMailbox(rawValue: candidate) != nil {
                mailbox = candidate
                query = String(query.dropFirst(first.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !query.isEmpty || mailbox != nil else { return nil }
        return NativeBrowserToolCall(
            name: .mailSearch,
            query: query,
            mailbox: mailbox
        )
    }

    private static func parseMailReadThread(_ text: String) -> NativeBrowserToolCall? {
        guard let identifier = parseIdentifier(text) else { return nil }
        return NativeBrowserToolCall(
            name: .mailReadThread,
            messageID: identifier.kind == .message ? identifier.value : nil,
            threadID: identifier.kind == .thread ? identifier.value : nil
        )
    }

    private static func parseMailDraftReply(_ text: String) -> NativeBrowserToolCall? {
        let pieces = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        guard let identifier = parseIdentifier(String(pieces[0])) else { return nil }
        let body = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return NativeBrowserToolCall(
            name: .mailDraftReply,
            messageID: identifier.kind == .message ? identifier.value : nil,
            threadID: identifier.kind == .thread ? identifier.value : nil,
            body: body
        )
    }

    private static func parseIdentifier(_ text: String) -> MailToolMessageIdentifier? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("thread:") {
            let value = String(trimmed.dropFirst("thread:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : MailToolMessageIdentifier(kind: .thread, value: value)
        }
        if lowered.hasPrefix("message:") {
            let value = String(trimmed.dropFirst("message:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : MailToolMessageIdentifier(kind: .message, value: value)
        }
        return MailToolMessageIdentifier(kind: .message, value: trimmed)
    }

    private static func inferredMailSearch(from text: String) -> NativeBrowserToolCall? {
        let normalized = normalizedWords(in: text)
        guard !normalized.isEmpty else { return nil }

        let words = Set(normalized.split(separator: " ").map(String.init))
        let mentionsMail = !words.isDisjoint(with: Set(["mail", "mails", "email", "emails", "inbox"]))
        guard mentionsMail else { return nil }

        let asksToList = !words.isDisjoint(with: Set([
            "what", "whats", "show", "list", "see", "view", "check",
            "have", "got", "new", "latest", "recent", "unread", "inbox"
        ]))
        guard asksToList else { return nil }

        let mailbox = inferredMailbox(words: words)
        let query = inferredQuery(words: words, normalized: normalized)
        return NativeBrowserToolCall(
            name: .mailSearch,
            query: query,
            mailbox: mailbox.rawValue,
            maxResults: 10
        )
    }

    private static func inferredMailbox(words: Set<String>) -> GmailMailbox {
        if words.contains("starred") { return .starred }
        if words.contains("sent") { return .sent }
        if words.contains("draft") || words.contains("drafts") { return .drafts }
        if words.contains("all") { return .all }
        return .inbox
    }

    private static func inferredQuery(words: Set<String>, normalized: String) -> String {
        if words.contains("unread") { return "is:unread" }
        let tokens = normalized.split(separator: " ").map(String.init)
        if let fromIndex = tokens.firstIndex(of: "from"), tokens.indices.contains(fromIndex + 1) {
            let sender = tokens[fromIndex + 1]
            if !["me", "my", "the", "a", "an"].contains(sender) {
                return "from:\(sender)"
            }
        }
        return ""
    }

    private static func normalizedWords(in text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
