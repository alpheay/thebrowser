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
    case mailReadCurrent = "mail_read_current"
    case mailShow = "mail_show"
    case mailDraft = "mail_draft"
    case mailCompose = "mail_compose"
    case mailSend = "mail_send"
    case mailModify = "mail_modify"
    case mailTriage = "mail_triage"
    case mailMemory = "mail_memory"
    case mailRemind = "mail_remind"
    case createArtifact = "create_artifact"
    case webControl = "web_control"

    /// True for the intelligent-inbox tools, which share a single executor
    /// closure and carry their rich parameters in `rawArguments`.
    var isMail: Bool {
        switch self {
        case .mailSearch, .mailReadThread, .mailReadCurrent, .mailShow, .mailDraft, .mailCompose, .mailSend,
             .mailModify, .mailTriage, .mailMemory, .mailRemind:
            return true
        default:
            return false
        }
    }
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
    /// The raw JSON object string of the tool call, preserved for mail tools so
    /// `MailToolService` can read their richer parameter set without bloating
    /// this shared struct. Nil for non-mail tools.
    var rawArguments: String? = nil

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
        case .mailReadThread, .mailShow, .mailRemind:
            return mailIdentifier?.displayValue ?? (query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? mailbox ?? "")
        case .mailDraft:
            return mailIdentifier?.displayValue ?? "new message"
        case .mailCompose:
            return "composer"
        case .mailReadCurrent:
            return "current email"
        case .mailSend:
            return mailIdentifier?.displayValue ?? "draft"
        case .mailModify:
            return messageID ?? "messages"
        case .mailTriage:
            return "inbox"
        case .mailMemory:
            return "memory"
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
            ?? (name.isMail ? stringValue(named: "id", in: dictionary, arguments: arguments) : nil)
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
            maxResults: maxResults,
            rawArguments: name.isMail ? json : nil
        )

        switch name {
        case .open, .fetch, .search, .webControl:
            return call.rawInput.isEmpty ? nil : call
        case .readTabs, .readHighlights, .readSmartRead:
            return call
        case .mailSearch, .mailReadThread, .mailReadCurrent, .mailShow, .mailDraft, .mailCompose, .mailSend,
             .mailModify, .mailTriage, .mailMemory, .mailRemind:
            // Mail tools validate their own arguments in MailToolService and
            // return a helpful error rather than failing the parse silently.
            return call
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

enum StreamingToolCallMask {
    /// Returns the prefix of an in-progress streamed response that's safe
    /// to show the user — strips any trailing JSON object that's likely
    /// to be a tool call.
    ///
    /// Two cases are stripped:
    ///   1. **In-progress JSON**: a `{` at the start of a line (or at
    ///      the very start of the buffer, optionally preceded by
    ///      whitespace) has been opened but not yet closed. Everything
    ///      from that `{` onward is hidden so the model's
    ///      mid-emission `"tool":"mail_se` doesn't flash in the bubble.
    ///   2. **Completed trailing JSON**: a top-level JSON object that
    ///      starts at a line boundary, closes, and is followed only by
    ///      whitespace. This is a fully-typed tool call sitting at the
    ///      end of the response — hide it.
    ///
    /// Embedded JSON (mid-prose `{example}` followed by more text) is
    /// preserved unchanged — those aren't tool calls and stripping them
    /// would damage the visible answer.
    ///
    /// The function tracks JSON string literals so braces inside quoted
    /// values don't confuse the depth counter, and falls back to
    /// returning the original input on malformed sequences (extra
    /// closing braces) rather than over-trimming.
    static func visiblePrefix(in text: String) -> String {
        var depth = 0
        var inString = false
        var escaped = false
        var lastTopLevelOpenIndex: String.Index? = nil

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
                if depth == 0, isAtLineStart(text: text, index: index) {
                    lastTopLevelOpenIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 {
                    // Malformed JSON balance — bail and show the input
                    // unchanged. The post-stream parser will decide
                    // whether anything in here is a real tool call.
                    return text
                }
            }
        }

        guard let openIndex = lastTopLevelOpenIndex else {
            return text
        }

        // Still inside the trailing JSON object — strip everything from
        // its opening brace on. Covers the common "model is mid-typing
        // the JSON" case.
        if depth > 0 {
            return cutPrefix(text, before: openIndex)
        }

        // Top-level object closed. Check that nothing non-whitespace
        // follows its close — if there's trailing prose, treat the
        // brace pair as embedded JSON (probably an example) and leave
        // the buffer untouched.
        guard let closeIndex = findMatchingClose(in: text, from: openIndex) else {
            return text
        }

        let afterClose = text[text.index(after: closeIndex)..<text.endIndex]
        if afterClose.contains(where: { !$0.isWhitespace }) {
            return text
        }

        return cutPrefix(text, before: openIndex)
    }

    /// True when the run of characters immediately before `index` is
    /// either empty, all whitespace, or contains a newline — i.e. the
    /// `{` at `index` opens on a fresh line. This is how we
    /// distinguish a tool-call-shaped JSON object from one embedded
    /// mid-sentence ("`Use {example}` like this").
    private static func isAtLineStart(text: String, index: String.Index) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if character.isNewline { return true }
            if !character.isWhitespace { return false }
        }
        return true
    }

    /// Returns the index of the `}` that closes the top-level JSON
    /// object starting at `openIndex`. Falls back to `nil` for
    /// malformed input.
    private static func findMatchingClose(in text: String, from openIndex: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false

        for index in text[openIndex..<text.endIndex].indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
                if depth < 0 { return nil }
            }
        }
        return nil
    }

    /// Trims `text` to everything strictly before `cutoffIndex`, also
    /// dropping any whitespace immediately preceding that point so the
    /// visible body doesn't end in a dangling blank line where the
    /// JSON used to sit.
    private static func cutPrefix(_ text: String, before cutoffIndex: String.Index) -> String {
        var cursor = cutoffIndex
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace {
                cursor = previous
            } else {
                break
            }
        }
        return String(text[text.startIndex..<cursor])
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
    /// transcript and just keeps the name, raw input, outcome, and a
    /// truncated copy of the captured output so the chat can show an
    /// expandable detail card without holding the entire prompt
    /// continuation in memory forever.
    var invocation: ChatMessage.ToolInvocation {
        ChatMessage.ToolInvocation(
            tool: call.name.rawValue,
            input: call.rawInput,
            status: succeeded ? .completed : .failed,
            output: invocationDisplayOutput,
            artifactURL: artifactURL
        )
    }

    /// 4 KB-ish snapshot of the captured tool output, with leading/trailing
    /// whitespace trimmed. Long results are clipped with an ellipsis so the
    /// session JSON doesn't explode when a fetch returns a 200 KB document.
    private var invocationDisplayOutput: String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limit = 4_000
        if trimmed.count <= limit {
            return trimmed
        }
        return String(trimmed.prefix(limit)) + "\n…\n[Output truncated. \(trimmed.count) characters total.]"
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
    /// Single entry point for every `mail_*` tool. The chat layer wires this to
    /// `MailToolService.handle`, which owns Gmail access + the intelligent
    /// inbox. Replaces the old per-capability mail closures.
    var runMailTool: @MainActor (_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult
    var saveAndOpenArtifact: @MainActor (_ title: String, _ html: String) async throws -> URL
    var runWebControl: @MainActor (_ task: String) async -> WebControlAgentOutcome

    init(
        openURL: @escaping @MainActor (URL) -> Void,
        readTabsContent: @escaping @MainActor ([Int]?) async -> String,
        readHighlightsContent: @escaping @MainActor ([Int]?) async -> String,
        smartReadContent: @escaping @MainActor () async -> String,
        runMailTool: @escaping @MainActor (_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult = { call in
            NativeBrowserToolResult(call: call, succeeded: false, content: NativeMailToolError.unavailable.errorDescription ?? "Mail tools are unavailable.")
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
        self.runMailTool = runMailTool
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
        case .mailSearch, .mailReadThread, .mailReadCurrent, .mailShow, .mailDraft, .mailCompose, .mailSend,
             .mailModify, .mailTriage, .mailMemory, .mailRemind:
            return await runMailTool(call)
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
    - mail_search: searches/lists the connected Gmail account for OTHER mail and returns STRUCTURED JSON results. SILENT — it does not change the screen. Use it to find mail the user is NOT already looking at. Pass `query` (Gmail search syntax); `natural_language:true` translates plain English; optional `mailbox` (inbox|starred|sent|drafts|all), `max_results` (default 12), `page_token`. DO NOT use mail_search to answer "what am I looking at" or to find the open email — if CURRENT SURFACE shows an open email, answer from it or call mail_read_current.
    - mail_read_thread: reads a full Gmail thread, all messages (silent). Pass `message_id` or `thread_id`. Set `summarize:true` to prepend a short AI summary.
    - mail_read_current: reads the FULL email/thread the user currently has open (the one in CURRENT SURFACE) — no arguments. Use this for "what does this say", "read this", "summarize this" when an email is open, instead of searching. Set `summarize:true` for a short AI summary.
    - mail_show: the ONLY tool that changes the user's screen — it opens/switches the inbox UI. Pass `message_id`/`thread_id` to open a thread, or `mailbox`/`query` to open a filtered list. Use it to OPEN mail or switch to a different view. Do NOT call it when CURRENT SURFACE is already MAIL — the inbox is open; read or act on what's there instead of re-opening it.
    - mail_draft: writes a reply (or new email) in the user's voice and stages it as a reviewable draft card. For a reply pass `message_id` or `thread_id` (+ optional `instructions`, optional `style`). For a new email pass `to` (+ `subject`, `instructions`). Pass `body` to use exact text verbatim. This NEVER sends — it only stages a draft.
    - mail_compose: writes or revises the email the user is composing in their NATIVE composer (in place, not a card). Use this whenever the user wants to write or change the email they're currently typing. Pass `instruction` to draft from scratch or edit the current body ("make it more formal", "shorten this", "add a line about the timeline", "finish it", "reword the opening"), or `body` to replace it verbatim; optional `to` / `subject`. If no composer is open and an email is open, it starts a reply to that email first.
    - mail_send: routes a staged draft through the user's send policy. Pass `draft_id` from a mail_draft result, or `to`+`body` (+`subject`,`thread_id`). It may send immediately or stage for the user to confirm depending on the user's send mode — READ the result and do NOT claim it was sent unless the result text says "Sent".
    - mail_modify: organizes mail in bulk (silent). Pass `message_ids` (array) plus any of `archive:true`, `read:true|false`, `star:true|false`, `add_labels`/`remove_labels` (Gmail label ids).
    - mail_triage: classifies inbox messages into AI labels and applies them. Optional `scope` ("inbox" default, "all" to re-classify everything).
    - mail_memory: manages durable memories. `action` = add (with `text`, optional `anchor` such as "email:a@b.com"/"domain:b.com"/"always"/"activity:scheduling", optional `kind`), list, search (`query`), or delete (`id`).
    - mail_remind: sets a follow-up reminder on a thread. Pass `message_id`/`thread_id` and `when` (natural language: "in 3 days", "next monday"), optional `note`.
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
    {"tool":"mail_search","query":"invoices from finance last week","natural_language":true}
    {"tool":"mail_read_thread","thread_id":"thread-id-from-search","summarize":true}
    {"tool":"mail_read_current"}
    {"tool":"mail_show","mailbox":"inbox"}
    {"tool":"mail_draft","message_id":"message-id-from-search","instructions":"Politely decline and propose next week."}
    {"tool":"mail_compose","instruction":"Make it warmer and confirm Tuesday at 2pm works."}
    {"tool":"mail_send","draft_id":"the-draft-id-from-mail_draft"}
    {"tool":"mail_modify","message_ids":["id1","id2"],"archive":true}
    {"tool":"mail_triage","scope":"inbox"}
    {"tool":"mail_memory","action":"add","text":"Prefers afternoon meetings","anchor":"email:sam@acme.com"}
    {"tool":"mail_remind","thread_id":"thread-id","when":"in 3 days","note":"chase the contract"}
    {"tool":"create_artifact","title":"Market Overview","html":"<!doctype html><html>…</html>"}
    {"tool":"web_control","task":"On the current page, play one game of Wordle and report the outcome."}

    CRITICAL tool-call rules — follow these or the dispatcher will treat your tool call as plain chat text and the action will silently fail:
    1. EXACTLY ONE tool call per response. Never emit two JSON objects in the same response. If you need read_tabs THEN create_artifact, emit only the read_tabs call now and wait for the result before emitting create_artifact in your next turn.
    2. A short one-line commentary BEFORE the JSON is OK and encouraged on chained turns — it helps the user understand what you're doing between tools (e.g. "Now checking your inbox." then the JSON on the next line). Keep it under one sentence. If you have nothing useful to say, omit the commentary and emit just the JSON.
    3. The JSON tool call MUST be the LAST thing in your response, on its own line(s), starting with `{` and ending with `}`. Anything written AFTER the closing `}` will be treated as a normal chat answer and your tool call will silently fail.
    4. No trailing summary, no "let me know if that worked", no markdown headings. The JSON object must end the response.
    5. When you need to describe what a tool does to the user, use plain English. Do not paste JSON examples into chat answers.

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
    /mail_draft [message:<id>|thread:<id>|<message-id>] | <reply body>
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
        case "/mail_draft":
            return parseMailDraft(remainder)
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

    private static func parseMailDraft(_ text: String) -> NativeBrowserToolCall? {
        let pieces = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        guard let identifier = parseIdentifier(String(pieces[0])) else { return nil }
        let body = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return NativeBrowserToolCall(
            name: .mailDraft,
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
