import AppKit
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        case system
    }

    /// One link in the tool chain for an assistant turn. Captures the tool
    /// the model invoked, the argument it passed (URL or query), the
    /// current status of the call, and an optional snippet of the captured
    /// output so the chip can be expanded into a detail card without
    /// re-running the call. `artifactURL` is set only for successful
    /// `create_artifact` calls so the chip can re-open the saved file.
    struct ToolInvocation: Equatable, Hashable {
        enum Status: Equatable, Hashable {
            case running
            case completed
            case failed
        }

        var id = UUID()
        var tool: String
        var input: String
        var status: Status
        var output: String? = nil
        var artifactURL: URL? = nil

        /// Back-compat read-only accessor — most call sites still ask
        /// "did this tool succeed?" rather than the full status.
        var succeeded: Bool { status == .completed }

        init(
            id: UUID = UUID(),
            tool: String,
            input: String,
            status: Status,
            output: String? = nil,
            artifactURL: URL? = nil
        ) {
            self.id = id
            self.tool = tool
            self.input = input
            self.status = status
            self.output = output
            self.artifactURL = artifactURL
        }

        /// Convenience initializer kept for historical call sites that
        /// pass `succeeded: Bool` directly. Maps it to the new status
        /// enum so the rest of the harness can rely on `status`.
        init(tool: String, input: String, succeeded: Bool, artifactURL: URL? = nil) {
            self.init(
                tool: tool,
                input: input,
                status: succeeded ? .completed : .failed,
                output: nil,
                artifactURL: artifactURL
            )
        }
    }

    let id = UUID()
    var role: Role
    var text: String
    var toolChain: [ToolInvocation] = []
    var attachments: [ChatAttachment] = []
    /// True while this message represents the in-flight assistant turn —
    /// text is partial, tools may still be running. The UI uses this to
    /// show streaming affordances (cursor, shimmer footer, etc.) and to
    /// suppress decorations like the copy button until the turn finishes.
    var isStreaming: Bool = false
    /// Short contextual label rendered alongside the streaming shimmer
    /// ("Running mail_search…", "Reading 2 tabs…"). Cleared when the turn
    /// is fully resolved.
    var statusLabel: String? = nil
}

/// A snippet of page text the user clipped via the in-page selection widget
/// (or any future attachment surface) and queued as additional context for
/// the next chat turn. Attachments are first-class — they live with the
/// user message they were sent with, persist into session history, and are
/// formatted into the AI prompt as a structured "Highlighted passages" block
/// so the model can cite them precisely.
struct ChatAttachment: Identifiable, Equatable, Hashable {
    let id: UUID
    var text: String
    var pageTitle: String
    var pageURL: String

    init(
        id: UUID = UUID(),
        text: String,
        pageTitle: String,
        pageURL: String
    ) {
        self.id = id
        self.text = text
        self.pageTitle = pageTitle
        self.pageURL = pageURL
    }

    /// Best label for the chip: the page title when known, otherwise the
    /// host, otherwise a generic "Highlight" fallback.
    var displayLabel: String {
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let host = host, !host.isEmpty { return host }
        return "Highlight"
    }

    var host: String? {
        guard let url = URL(string: pageURL) else { return nil }
        return url.host(percentEncoded: false)
    }

    /// Short single-line preview of the clipped text, for tooltips and
    /// compact chip captions. Collapses whitespace and caps length.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count > 140 {
            return String(collapsed.prefix(140)) + "…"
        }
        return collapsed
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    /// The in-flight assistant turn. Rendered as the bottom-most bubble
    /// while a reply is being produced; mutated in place as text streams
    /// in and tool calls fire, then moved into `messages` once finalized.
    /// Keeping it out-of-band from `messages` lets the UI distinguish
    /// finalized rows (markdown, copy button, no spinner) from the live
    /// row (status footer, in-progress tool chips, suppressed copy
    /// button) without sprinkling `isStreaming` checks across the list.
    @Published var liveMessage: ChatMessage?
    @Published var draft = ""
    @Published var isSending = false
    @Published var focusComposerToken = 0
    @Published var pendingAttachments: [ChatAttachment] = []
    /// When non-nil, the composer is in "draft from clips" mode: a row of
    /// preset tiles is shown above the field, and `send` prepends the
    /// preset's drafting rubric to the prompt sent to the model. Cleared
    /// after a successful send or when the user dismisses the bar.
    @Published var draftPreset: CitedClipDraftPreset?
    @Published private(set) var sessionID: String

    private let client = AIProviderClient()
    private let store = ChatSessionStore.shared
    /// The Swift Task currently driving the agent loop, plus the
    /// AgentRunHandle that lets us kill its subprocess. Both are non-nil
    /// while a turn is in flight; tearing them down (or being torn down
    /// by `cancelCurrent`) finalizes the live message.
    private var currentTask: Task<Void, Never>?
    private var currentRunHandle: AgentRunHandle?

    init() {
        self.sessionID = ChatSessionStore.shared.newSessionID()
    }

    /// Switches the composer into draft mode with the supplied clips queued
    /// as first-class attachments. Each clip becomes a `ChatAttachment`
    /// (deduplicated against anything the user already has pending), the
    /// `Note` preset is selected by default, and the composer is focused.
    func beginDraftFromClips(_ clips: [CitedClip]) {
        for clip in clips {
            let trimmed = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let already = pendingAttachments.contains { existing in
                existing.text == trimmed && existing.pageURL == clip.sourceURL
            }
            guard !already else { continue }
            pendingAttachments.append(ChatAttachment(
                text: trimmed,
                pageTitle: clip.sourceTitle,
                pageURL: clip.sourceURL
            ))
        }
        if draftPreset == nil {
            draftPreset = .note
        }
        focusComposer()
    }

    func cancelDraftMode() {
        draftPreset = nil
    }

    /// Flattens every attachment ever sent in this conversation into a
    /// stable, globally-numbered list (1-based, oldest first). The number
    /// the model sees in the prompt — e.g. `[2]` — maps directly back to
    /// `result.index` here.
    func enumeratedAttachments() -> [(index: Int, messageID: ChatMessage.ID, attachment: ChatAttachment)] {
        var results: [(Int, ChatMessage.ID, ChatAttachment)] = []
        var counter = 0
        for msg in messages where msg.role == .user {
            for att in msg.attachments {
                counter += 1
                results.append((counter, msg.id, att))
            }
        }
        return results
    }

    /// Resolves a `read_highlights` tool call against the conversation's
    /// global attachment numbering. `indices` is 1-based; nil means "give
    /// me every highlight in this conversation." Returns a formatted text
    /// block that mirrors the inline format used for current-turn
    /// highlights, so the model sees the same shape whether the content
    /// arrived in the prompt or via the tool result.
    func collectAttachments(indices: [Int]?) -> String {
        let all = enumeratedAttachments()
        guard !all.isEmpty else {
            return "No highlighted passages have been attached in this conversation."
        }

        let selected: [(Int, ChatMessage.ID, ChatAttachment)]
        if let indices, !indices.isEmpty {
            let wanted = Set(indices)
            selected = all.filter { wanted.contains($0.0) }
        } else {
            selected = all
        }

        guard !selected.isEmpty else {
            let available = all.map { String($0.0) }.joined(separator: ", ")
            return "No highlight matches the requested index. Available indices: \(available)."
        }

        var sections: [String] = []
        for (idx, _, attachment) in selected {
            let title = attachment.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = attachment.pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: String
            if !title.isEmpty && !url.isEmpty {
                source = "\(title) — \(url)"
            } else if !title.isEmpty {
                source = title
            } else if !url.isEmpty {
                source = url
            } else {
                source = "unknown source"
            }
            var lines: [String] = ["[\(idx)] From \(source):"]
            for piece in attachment.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(piece)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Queues a highlighted page passage as additional context for the
    /// next chat turn. Deduplicates identical highlights from the same URL
    /// so users can spam the Ask button without piling up duplicates.
    func attachHighlight(text: String, pageContext: BrowserPageContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let already = pendingAttachments.contains { existing in
            existing.text == trimmed && existing.pageURL == pageContext.url
        }
        guard !already else { return }
        pendingAttachments.append(ChatAttachment(
            text: trimmed,
            pageTitle: pageContext.title,
            pageURL: pageContext.url
        ))
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    /// The directory that backs the current session. Persisted at
    /// ``~/.thebrowser/sessions/<sessionID>``.
    var sessionDirectory: URL {
        store.directory(for: sessionID)
    }

    func send(
        context: BrowserPageContext,
        tabs: [TabManifestEntry],
        nativeTools: NativeBrowserToolExecutor,
        smartReadActive: Bool = false
    ) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let activePreset = draftPreset
        // Custom preset needs an explicit instruction — its rubric is empty.
        if activePreset == .custom, trimmed.isEmpty {
            return
        }
        // Allow sending when there's an attached highlight even if the text
        // box is empty — the attachment carries the question's subject.
        guard (!trimmed.isEmpty || !pendingAttachments.isEmpty), !isSending else {
            return
        }

        let attachmentsForTurn = pendingAttachments
        pendingAttachments.removeAll()

        // The visible user bubble is what the user typed; for a draft turn
        // with no typed text, fall back to a "Draft <preset>" label so the
        // history row isn't blank. The prompt sent to the model is built
        // separately below and carries the full preset rubric.
        let userText: String
        if let preset = activePreset {
            userText = trimmed.isEmpty
                ? "Draft a \(preset.displayName.lowercased()) from \(attachmentsForTurn.count) source\(attachmentsForTurn.count == 1 ? "" : "s")."
                : trimmed
        } else {
            userText = trimmed.isEmpty ? "What can you tell me about the highlighted passage?" : trimmed
        }

        let promptText: String
        if let preset = activePreset {
            var pieces: [String] = []
            pieces.append("Drafting task — format: \(preset.displayName).")
            if !preset.instruction.isEmpty {
                pieces.append(preset.instruction)
            }
            pieces.append("Use the highlighted passages above as your source material and cite each one inline with its bracketed index.")
            if !trimmed.isEmpty {
                pieces.append("Additional instructions from the user: \(trimmed)")
            }
            promptText = pieces.joined(separator: "\n\n")
        } else {
            promptText = userText
        }

        let directMailCommandRequested = activePreset == nil
            && attachmentsForTurn.isEmpty
            && trimmed.hasPrefix("/mail_")
        let canUseDirectTool = activePreset == nil && attachmentsForTurn.isEmpty
        let directToolCall = canUseDirectTool
            ? DirectNativeToolCommand.parse(trimmed)
            : nil

        messages.append(ChatMessage(role: .user, text: userText, attachments: attachmentsForTurn))
        draft = ""
        draftPreset = nil
        isSending = true
        // Spin up the live in-flight bubble immediately so the user sees
        // the agent "engage" before the first CLI subprocess returns.
        liveMessage = ChatMessage(
            role: .assistant,
            text: "",
            toolChain: [],
            isStreaming: true,
            statusLabel: AgentStatusLabel.thinking
        )
        persist(context: context)

        if directMailCommandRequested && directToolCall == nil {
            // /mail_<unknown> — fall back to the inline help text, which
            // can finalize the live bubble synchronously.
            finalizeLiveMessage(text: DirectNativeToolCommand.helpText, context: context)
            isSending = false
            return
        }

        if let directToolCall {
            runDirectToolTurn(directToolCall, context: context, nativeTools: nativeTools)
            return
        }

        runAgentTurn(
            promptText: promptText,
            context: context,
            history: messages,
            tabs: tabs,
            attachments: attachmentsForTurn,
            smartReadActive: smartReadActive,
            nativeTools: nativeTools
        )
    }

    /// Stop button handler. Flips the run handle (which terminates any
    /// CLI subprocess currently in flight) and cancels the Swift Task —
    /// the loop will catch the cancellation at its next checkpoint and
    /// finalize the live message in `cancelled` state.
    func cancelCurrent() {
        guard isSending else { return }
        currentRunHandle?.cancel()
        currentTask?.cancel()
    }

    /// Direct-tool path (e.g. `/mail_search inbox newer_than:7d`): runs
    /// one tool natively, surfaces its progress through the same live
    /// bubble the model-driven path uses, then finalizes.
    private func runDirectToolTurn(
        _ call: NativeBrowserToolCall,
        context: BrowserPageContext,
        nativeTools: NativeBrowserToolExecutor
    ) {
        let handle = AgentRunHandle()
        currentRunHandle = handle

        currentTask = Task { @MainActor in
            defer {
                self.currentTask = nil
                self.currentRunHandle = nil
                self.isSending = false
                self.persist(context: context)
            }

            // Begin the tool chip in the live bubble so the user sees it
            // light up before the tool finishes.
            beginLiveTool(call: call)

            if handle.isCancelled || Task.isCancelled {
                completeLiveTool(status: .failed, output: "Stopped.")
                finalizeLiveMessage(
                    text: "Stopped.",
                    context: context,
                    role: .system
                )
                return
            }

            let result = await nativeTools.execute(call)
            completeLiveTool(
                status: result.succeeded ? .completed : .failed,
                output: result.invocation.output,
                artifactURL: result.invocation.artifactURL
            )
            finalizeLiveMessage(text: result.content, context: context)
        }
    }

    /// Model-driven agentic loop. Each iteration:
    ///   1. Runs the CLI to get the next assistant response.
    ///   2. Parses the response for a JSON tool call.
    ///   3. If a tool call: executes it live, appends results, continues.
    ///   4. If not: finalizes the live message with the response text.
    /// The loop bounds at `maxAgentIterations`; cancellation can interrupt
    /// any await point.
    private func runAgentTurn(
        promptText: String,
        context: BrowserPageContext,
        history: [ChatMessage],
        tabs: [TabManifestEntry],
        attachments: [ChatAttachment],
        smartReadActive: Bool,
        nativeTools: NativeBrowserToolExecutor
    ) {
        let directory = sessionDirectory
        let configuration = AIHarnessConfiguration.current()
        let basePrompt = AIProviderClient.prompt(
            for: promptText,
            context: context,
            history: history,
            configuration: configuration,
            tabs: tabs,
            attachments: attachments,
            smartReadActive: smartReadActive
        )

        let handle = AgentRunHandle()
        currentRunHandle = handle

        currentTask = Task { @MainActor in
            defer {
                self.currentTask = nil
                self.currentRunHandle = nil
                self.isSending = false
                self.persist(context: context)
            }

            var collectedResults: [NativeBrowserToolResult] = []
            var currentPrompt = basePrompt

            do {
                for iteration in 0..<maxAgentIterations {
                    if handle.isCancelled || Task.isCancelled {
                        throw AIProviderError.cancelled
                    }

                    // Snapshot whatever prose the bubble already carries
                    // (commentary from prior iterations) — we join new
                    // commentary onto this base, never overwrite it.
                    let baseTextBeforeIteration = liveMessage?.text ?? ""

                    setLiveStatus(AgentStatusLabel.thinking)
                    let response = try await streamIteration(
                        prompt: currentPrompt,
                        sessionDirectory: directory,
                        runHandle: handle,
                        supportsStreaming: configuration.supportsStreamingEvents
                    )

                    if handle.isCancelled || Task.isCancelled {
                        throw AIProviderError.cancelled
                    }

                    // Apply the tool-call mask uniformly. For the
                    // streaming path the bubble already reflects this
                    // (the mask ran on every delta), so this is
                    // idempotent. For Codex / fallback paths it's the
                    // first place we strip the JSON tail out.
                    let iterationVisible = StreamingToolCallMask.visiblePrefix(in: response)
                    let composed = Self.composeLiveText(
                        base: baseTextBeforeIteration,
                        iterationVisible: iterationVisible
                    )
                    overwriteLiveText(composed)

                    // No tool call in the response — this is the final
                    // model utterance for the turn. Finalize with the
                    // composed bubble so all prior commentary survives.
                    guard let call = NativeBrowserToolCall.parse(from: response) else {
                        finalizeLiveMessage(text: composed, context: context)
                        return
                    }

                    // Tool call detected. The bubble already shows the
                    // composed pre-tool commentary (if the model wrote
                    // any) — no rewind needed.

                    // Surface the tool as `.running` immediately so the
                    // user sees the chip light up before the work starts.
                    beginLiveTool(call: call)

                    let result = await nativeTools.execute(call)
                    collectedResults.append(result)
                    completeLiveTool(
                        status: result.succeeded ? .completed : .failed,
                        output: result.invocation.output,
                        artifactURL: result.invocation.artifactURL
                    )

                    if iteration == maxAgentIterations - 1 {
                        // We hit the ceiling without a final answer. Show
                        // the last tool's text so the user can at least
                        // see what the agent was producing.
                        let trailer = "I used several browser tools and stopped to avoid looping.\n\n\(result.promptText)"
                        finalizeLiveMessage(text: trailer, context: context)
                        return
                    }

                    currentPrompt = NativeBrowserToolPrompt.continuationPrompt(
                        basePrompt: basePrompt,
                        results: collectedResults
                    )
                }
            } catch AIProviderError.cancelled {
                rollbackInflightTool()
                let partial = liveMessage?.text ?? ""
                finalizeLiveMessage(
                    text: partial.isEmpty ? "Stopped." : partial,
                    context: context,
                    role: partial.isEmpty ? .system : .assistant
                )
            } catch {
                rollbackInflightTool()
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                finalizeLiveMessage(text: description, context: context, role: .system)
            }
        }
    }

    /// Pushes a `.running` tool chip into the live bubble. Status label
    /// flips to the tool-specific phrasing so the shimmer matches.
    private func beginLiveTool(call: NativeBrowserToolCall) {
        guard var live = liveMessage else { return }
        live.toolChain.append(ChatMessage.ToolInvocation(
            tool: call.name.rawValue,
            input: call.rawInput,
            status: .running
        ))
        live.statusLabel = AgentStatusLabel.forActiveTool(call)
        liveMessage = live
    }

    /// Resolves the last `.running` tool chip with its captured output.
    /// Falls back to a no-op if the chain is empty (shouldn't happen, but
    /// keeps the harness defensive against weird race conditions).
    private func completeLiveTool(
        status: ChatMessage.ToolInvocation.Status,
        output: String?,
        artifactURL: URL? = nil
    ) {
        guard var live = liveMessage, !live.toolChain.isEmpty else { return }
        let lastIndex = live.toolChain.count - 1
        live.toolChain[lastIndex].status = status
        live.toolChain[lastIndex].output = output
        live.toolChain[lastIndex].artifactURL = artifactURL
        liveMessage = live
    }

    /// Marks any trailing `.running` tool entry as `.failed`. Used on the
    /// cancellation / error path so the chip doesn't get frozen in its
    /// spinner state when the turn unwinds.
    private func rollbackInflightTool() {
        guard var live = liveMessage, !live.toolChain.isEmpty else { return }
        let lastIndex = live.toolChain.count - 1
        if live.toolChain[lastIndex].status == .running {
            live.toolChain[lastIndex].status = .failed
            live.toolChain[lastIndex].output = "Stopped."
        }
        liveMessage = live
    }

    private func setLiveStatus(_ label: String?) {
        guard var live = liveMessage else { return }
        live.statusLabel = label
        liveMessage = live
    }

    /// One iteration of the agent loop. For providers that support
    /// `--output-format stream-json` (currently just Claude), text
    /// deltas are forwarded into `liveMessage.text` as they arrive so
    /// the bubble fills in live. For non-streaming providers (Codex),
    /// the full response surfaces as a single block once the call
    /// completes, identical to the old behavior.
    private func streamIteration(
        prompt: String,
        sessionDirectory: URL,
        runHandle: AgentRunHandle,
        supportsStreaming: Bool
    ) async throws -> String {
        if supportsStreaming {
            return try await streamingAsk(
                prompt: prompt,
                sessionDirectory: sessionDirectory,
                runHandle: runHandle
            )
        }
        return try await askWithRetry(
            prompt: prompt,
            sessionDirectory: sessionDirectory,
            runHandle: runHandle
        )
    }

    /// Drives `client.askStream` while pushing each text delta into the
    /// live bubble. Returns the authoritative final text — usually the
    /// same as the concatenated deltas, but the consumer trusts the
    /// `.result` payload so we don't have to parse mid-stream.
    ///
    /// Retries are intentionally NOT layered on top of the streaming
    /// path: a partial mid-stream response is too messy to recover from
    /// cleanly (we'd have to rewind the visible text, retry, and hope
    /// the second response matches). Streaming is best-effort fast-path;
    /// the askWithRetry fallback covers the cases that matter.
    private func streamingAsk(
        prompt: String,
        sessionDirectory: URL,
        runHandle: AgentRunHandle
    ) async throws -> String {
        // Prior-iteration commentary already in the bubble. New text
        // from this iteration joins onto this base; we never overwrite
        // it so chained "doing X… now doing Y…" stories survive.
        let baseText = liveMessage?.text ?? ""
        var iterationBuffer = ""
        var accumulated = ""

        let stream = client.askStream(
            prompt: prompt,
            sessionDirectory: sessionDirectory,
            runHandle: runHandle
        )

        for try await event in stream {
            if runHandle.isCancelled || Task.isCancelled {
                throw AIProviderError.cancelled
            }
            switch event {
            case .textDelta(let chunk):
                accumulated += chunk
                iterationBuffer += chunk
                let visible = StreamingToolCallMask.visiblePrefix(in: iterationBuffer)
                overwriteLiveText(Self.composeLiveText(
                    base: baseText,
                    iterationVisible: visible
                ))
            case .result(let finalText):
                // Final authoritative answer. Reconcile by re-running
                // the mask against the canonical text so the bubble
                // ends in the same masked-prose state we'd have hit if
                // every delta had matched the result.
                if finalText != accumulated {
                    let visible = StreamingToolCallMask.visiblePrefix(in: finalText)
                    overwriteLiveText(Self.composeLiveText(
                        base: baseText,
                        iterationVisible: visible
                    ))
                }
                return finalText
            }
        }

        // Stream ended without a `.result` event — fall back to whatever
        // we accumulated. Empty here means the provider returned nothing
        // usable; surface that as an empty-response error so the loop's
        // catch handler can show a system pill.
        if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProviderError.emptyResponse
        }
        return accumulated
    }

    /// Joins prior-iteration commentary (`base`) with the masked text
    /// from the current iteration (`iterationVisible`) using a paragraph
    /// break, so chained "doing X" lines from successive turns read as
    /// separate thoughts rather than a single run-on string.
    /// Trims trailing whitespace on the new piece so the bubble doesn't
    /// end with a hanging newline where the JSON used to sit.
    static func composeLiveText(base: String, iterationVisible: String) -> String {
        let trimmedVisible = iterationVisible.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return trimmedVisible }
        if trimmedVisible.isEmpty { return base }
        return base + "\n\n" + trimmedVisible
    }

    private func overwriteLiveText(_ text: String) {
        guard var live = liveMessage else { return }
        live.text = text
        liveMessage = live
    }

    /// Commits the in-flight bubble: clears its streaming flag and status
    /// row, sets the final text, and moves it into `messages`. Passing
    /// `role: .system` instead surfaces the text as a system pill (used
    /// for harness errors and quiet cancellation messages).
    private func finalizeLiveMessage(
        text: String,
        context: BrowserPageContext,
        role: ChatMessage.Role = .assistant
    ) {
        let toolChain = liveMessage?.toolChain ?? []
        let attachments = liveMessage?.attachments ?? []
        // For system messages we drop the tool chain — the system pill is
        // just a one-liner ("Stopped." or "Claude exited with status 1");
        // the partial tool chain (if any) was either already shown live
        // and rolled back, or wasn't relevant to the failure.
        let finalized = ChatMessage(
            role: role,
            text: text,
            toolChain: role == .assistant ? toolChain : [],
            attachments: attachments,
            isStreaming: false,
            statusLabel: nil
        )
        liveMessage = nil
        messages.append(finalized)
    }

    func clear() {
        // If a turn is mid-flight, kill it first so its task can't write
        // back into the next conversation's live bubble after we wipe.
        cancelCurrent()
        messages.removeAll()
        liveMessage = nil
        draft = ""
        draftPreset = nil
        pendingAttachments.removeAll()
        sessionID = store.newSessionID()
    }

    /// Switches to a previously persisted session, loading its messages off
    /// disk. Blocks while a reply is in flight so the streaming response can't
    /// land in the wrong session.
    func resume(sessionID: String, context: BrowserPageContext) {
        guard sessionID != self.sessionID, !isSending else { return }
        persist(context: context)
        self.sessionID = sessionID
        self.messages = store.load(sessionID: sessionID)
        self.liveMessage = nil
        self.draft = ""
    }

    func focusComposer() {
        focusComposerToken &+= 1
    }

    private func persist(context: BrowserPageContext) {
        store.save(messages: messages, sessionID: sessionID, pageContext: context)
    }

    private func askWithRetry(
        prompt: String,
        sessionDirectory: URL,
        runHandle: AgentRunHandle? = nil,
        attempts: Int = 2
    ) async throws -> String {
        var latestError: Error?
        var currentPrompt = prompt

        for attempt in 1...max(attempts, 1) {
            do {
                return try await client.ask(
                    prompt: currentPrompt,
                    sessionDirectory: sessionDirectory,
                    runHandle: runHandle
                )
            } catch {
                latestError = error
                guard attempt < attempts, shouldRetry(error) else { break }
                currentPrompt = """
                \(prompt)

                Retry notice:
                The previous model run failed or returned no usable message. Try again now. If a native tool is needed, reply with exactly one bare JSON tool call from the listed schema. For mail/inbox requests, use mail_search instead of asking the user for another query.
                """
            }
        }

        throw latestError ?? AIProviderError.emptyResponse
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        switch providerError {
        case .emptyResponse:
            return true
        case .processFailed:
            return true
        case .missingExecutable:
            return false
        case .cancelled:
            // Don't retry cancellation — the user explicitly asked to stop.
            return false
        }
    }
}

struct AIChatPanel: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var smartReadModel: SmartReadModel
    @ObservedObject var mailModel: MailModel
    var gmailStore: GmailStore
    var context: BrowserPageContext
    var tabs: [TabManifestEntry]
    var nativeTools: NativeBrowserToolExecutor
    var onOpenArtifact: (URL) -> Void
    var onClose: () -> Void

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @AppStorage(PreferenceKey.aiShowToolChain) private var showToolChain = true
    @FocusState private var composerFocused: Bool
    @State private var showingModelPicker = false
    @State private var showingHistoryPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            composer
        }
        .frame(width: Metrics.chatWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
        .onChange(of: viewModel.focusComposerToken) { _, _ in
            composerFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.surface)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                ProviderMark(provider: provider, size: 13)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Chat")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if viewModel.isSending {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 5, height: 5)
                            .modifier(BreathingPulse())
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                Text(provider.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textFaint)
            }

            Spacer(minLength: 8)

            HeaderIconButton(systemName: "clock.arrow.circlepath", help: "Resume previous conversation") {
                showingHistoryPicker.toggle()
            }
            .popover(isPresented: $showingHistoryPicker, arrowEdge: .bottom) {
                SessionHistoryPopover(currentSessionID: viewModel.sessionID) { id in
                    showingHistoryPicker = false
                    withAnimation(Motion.springSoft) {
                        viewModel.resume(sessionID: id, context: context)
                    }
                }
            }

            HeaderIconButton(systemName: "square.and.pencil", help: "New conversation") {
                withAnimation(Motion.springSoft) {
                    viewModel.clear()
                }
            }
            .opacity(viewModel.messages.isEmpty ? 0.35 : 1.0)
            .disabled(viewModel.messages.isEmpty)
            .animation(.easeOut(duration: 0.15), value: viewModel.messages.isEmpty)

            HeaderIconButton(systemName: "xmark", help: "Hide chat", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.clear, Palette.stroke, Palette.stroke, Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .animation(Motion.springSnap, value: viewModel.isSending)
    }

    // MARK: - Content (messages or empty state)

    @ViewBuilder
    private var content: some View {
        if smartReadModel.isPresented
            || !viewModel.messages.isEmpty
            || viewModel.liveMessage != nil
            || viewModel.isSending
            || !mailModel.pendingDrafts.isEmpty
            || !mailModel.memorySuggestions.isEmpty {
            messageList
        } else {
            EmptyChatState(
                providerName: provider.displayName,
                context: context,
                onSuggestion: { text in
                    viewModel.draft = text
                    composerFocused = true
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if smartReadModel.isPresented {
                        SmartReadCard(
                            phase: smartReadModel.phase,
                            onClose: {
                                withAnimation(Motion.springSnap) {
                                    smartReadModel.close()
                                }
                            }
                        )
                        .id("smart-read")
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -6)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        ))
                    }

                    ForEach(mailModel.pendingDrafts) { draft in
                        MailDraftCard(draft: draft, mail: mailModel, gmail: gmailStore)
                            .id("mail-draft-\(draft.id)")
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }

                    ForEach(mailModel.memorySuggestions) { suggestion in
                        MemorySuggestionToast(
                            memory: suggestion,
                            onKeep: { mailModel.acceptMemorySuggestion(id: suggestion.id) },
                            onDismiss: { mailModel.dismissMemorySuggestion(id: suggestion.id) }
                        )
                        .id("mail-memory-\(suggestion.id)")
                        .transition(.opacity)
                    }

                    ForEach(viewModel.messages) { message in
                        MessageView(
                            message: message,
                            showToolChain: showToolChain,
                            onOpenArtifact: onOpenArtifact
                        )
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity
                            ))
                    }

                    if let live = viewModel.liveMessage {
                        LiveAssistantMessage(
                            message: live,
                            showToolChain: showToolChain,
                            onOpenArtifact: onOpenArtifact
                        )
                        .id("live-message")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .animation(Motion.springSoft, value: viewModel.messages.count)
                .animation(Motion.springSoft, value: viewModel.liveMessage?.toolChain.count ?? 0)
                .animation(Motion.springSoft, value: viewModel.liveMessage?.statusLabel ?? "")
                .animation(Motion.springSnap, value: smartReadModel.isPresented)
                .animation(Motion.springSnap, value: smartReadModel.phase)
            }
            .scrollIndicators(.hidden)
            .mask(scrollFadeMask)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation(Motion.springSoft) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.liveMessage?.toolChain.count ?? 0) { _, _ in
                if viewModel.liveMessage != nil {
                    withAnimation(Motion.springSoft) {
                        proxy.scrollTo("live-message", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.liveMessage == nil) { _, isHidden in
                guard isHidden else {
                    withAnimation(Motion.springSoft) {
                        proxy.scrollTo("live-message", anchor: .bottom)
                    }
                    return
                }
            }
        }
    }

    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
            Color.black
            LinearGradient(
                colors: [Color.black, Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if viewModel.draftPreset != nil {
                DraftPresetBar(
                    selected: viewModel.draftPreset ?? .note,
                    onPick: { preset in
                        withAnimation(Motion.springSnap) {
                            viewModel.draftPreset = preset
                        }
                    },
                    onDismiss: {
                        withAnimation(Motion.springSnap) {
                            viewModel.cancelDraftMode()
                        }
                    }
                )
                .transition(.opacity.combined(with: .offset(y: 4)))
            }

            if !viewModel.pendingAttachments.isEmpty {
                pendingAttachmentsList
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }

            if !context.title.isEmpty || !context.url.isEmpty {
                HStack(spacing: 6) {
                    contextPill
                    Spacer(minLength: 0)
                }
            }

            ComposerField(
                draft: $viewModel.draft,
                focused: $composerFocused,
                placeholder: composerPlaceholder,
                onSubmit: sendCurrent
            ) {
                HStack(spacing: 6) {
                    ModelPickerButton(
                        provider: provider,
                        showingPicker: $showingModelPicker
                    )
                    if viewModel.isSending {
                        StopButton(action: viewModel.cancelCurrent)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else {
                        SendButton(
                            enabled: canSend,
                            sending: false,
                            action: sendCurrent
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(Motion.springSnap, value: viewModel.isSending)
            }
        }
        .padding(14)
        .padding(.bottom, 4)
        .animation(Motion.springSnap, value: viewModel.pendingAttachments.map(\.id))
        .animation(Motion.springSnap, value: viewModel.draftPreset)
    }

    /// Stack of queued highlights shown above the composer. Capped at three
    /// visible chips with a quiet "+N more" indicator beyond that so the
    /// composer doesn't grow without bound on a clipping spree.
    private var pendingAttachmentsList: some View {
        let attachments = viewModel.pendingAttachments
        let visibleLimit = 3
        let visible = Array(attachments.prefix(visibleLimit))
        let overflow = max(0, attachments.count - visibleLimit)
        return VStack(spacing: 6) {
            ForEach(visible) { attachment in
                PendingAttachmentChip(
                    attachment: attachment,
                    onRemove: {
                        withAnimation(Motion.springSnap) {
                            viewModel.removeAttachment(id: attachment.id)
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)),
                    removal: .opacity.combined(with: .scale(scale: 0.92))
                ))
            }
            if overflow > 0 {
                overflowFooter(count: overflow)
            }
        }
    }

    private func overflowFooter(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("+\(count) more highlight\(count == 1 ? "" : "s")")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.springSoft) {
                    viewModel.clearAttachments()
                }
            } label: {
                Text("Clear all")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove all queued highlights")
        }
        .padding(.horizontal, 4)
    }

    private var composerPlaceholder: String {
        if let preset = viewModel.draftPreset {
            switch preset {
            case .custom:
                return "Describe the draft you want…"
            default:
                return "Add notes for the \(preset.displayName.lowercased()) (or press send)…"
            }
        }
        if !viewModel.pendingAttachments.isEmpty {
            return "Ask about the highlight…"
        }
        return "Ask \(provider.displayName)…"
    }

    /// Wraps `ChatViewModel.send` with the current Smart Read state so the
    /// prompt builder knows whether to hint the model about the available
    /// summary and the `read_smart_read` tool.
    private func sendCurrent() {
        viewModel.send(
            context: context,
            tabs: tabs,
            nativeTools: nativeTools,
            smartReadActive: smartReadModel.isPresented
        )
    }

    private var canSend: Bool {
        if viewModel.isSending { return false }
        let hasText = !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // .custom needs an explicit instruction — the rubric is empty.
        if viewModel.draftPreset == .custom { return hasText }
        return hasText || !viewModel.pendingAttachments.isEmpty
    }

    private var provider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? .codex
    }

    private var contextPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 9, weight: .semibold))
            Text(context.title.isEmpty ? "Home" : context.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().stroke(Palette.stroke, lineWidth: 1))
    }

}

// MARK: - Header icon button

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Palette.text : Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(help)
    }
}

// MARK: - Composer field

private struct ComposerField<Trailing: View>: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var onSubmit: () -> Void
    @ViewBuilder var trailingButton: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "",
                text: $draft,
                prompt: Text(placeholder).foregroundColor(Palette.textMuted),
                axis: .vertical
            )
            .focused(focused)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1...10)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .onSubmit(onSubmit)
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.shift) {
                    return .ignored
                }
                onSubmit()
                return .handled
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(focused.wrappedValue ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(focused.wrappedValue ? Color.white.opacity(0.22) : Palette.stroke, lineWidth: 1)
            }
            .shadow(color: focused.wrappedValue ? Color.white.opacity(0.06) : Color.clear, radius: 12, x: 0, y: 0)
            .animation(.easeOut(duration: 0.16), value: focused.wrappedValue)

            trailingButton()
                .padding(.bottom, 4)
        }
    }
}

// MARK: - Empty state

private struct EmptyChatState: View {
    let providerName: String
    let context: BrowserPageContext
    let onSuggestion: (String) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Palette.surface)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 56, height: 56)
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 4) {
                Text("How can I help?")
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("Ask \(providerName) about this page or anything else.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)

            VStack(spacing: 6) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    SuggestionChip(
                        icon: suggestion.icon,
                        text: suggestion.text,
                        delay: 0.10 + Double(index) * 0.06,
                        appeared: appeared,
                        action: { onSuggestion(suggestion.text) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 24)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.04)) {
                appeared = true
            }
        }
    }

    private var suggestions: [Suggestion] {
        if !context.url.isEmpty {
            return [
                Suggestion(icon: "text.alignleft", text: "Summarize this page"),
                Suggestion(icon: "lightbulb", text: "Explain the key ideas"),
                Suggestion(icon: "questionmark.bubble", text: "What should I ask about this?"),
                Suggestion(icon: "envelope.open", text: "/mail_search inbox newer_than:7d")
            ]
        }
        return [
            Suggestion(icon: "globe", text: "Find me a great article on…"),
            Suggestion(icon: "lightbulb", text: "Explain a concept simply"),
            Suggestion(icon: "text.bubble", text: "Help me write something"),
            Suggestion(icon: "envelope.open", text: "/mail_search inbox newer_than:7d")
        ]
    }

    private struct Suggestion {
        let icon: String
        let text: String
    }
}

private struct SuggestionChip: View {
    let icon: String
    let text: String
    let delay: Double
    let appeared: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .opacity(isHovering ? 1 : 0)
                    .offset(x: isHovering ? 0 : -4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.55, dampingFraction: 0.9).delay(delay), value: appeared)
    }
}

// MARK: - Message bubbles

private struct MessageView: View {
    var message: ChatMessage
    var showToolChain: Bool
    var onOpenArtifact: (URL) -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.text, attachments: message.attachments)
        case .assistant:
            AssistantMessage(
                text: message.text,
                toolChain: showToolChain ? message.toolChain : [],
                onOpenArtifact: onOpenArtifact
            )
        case .system:
            SystemPill(text: message.text)
        }
    }
}

private struct UserBubble: View {
    var text: String
    var attachments: [ChatAttachment] = []
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(attachments) { attachment in
                            SentAttachmentChip(attachment: attachment)
                        }
                    }
                }

                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 14,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 14,
                            style: .continuous
                        )
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.13),
                                    Color.white.opacity(0.085)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .overlay {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 14,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 14,
                            style: .continuous
                        )
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    }
                    .frame(maxWidth: 270, alignment: .trailing)

                if isHovering {
                    CopyButton(text: text)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }
}

private struct AssistantMessage: View {
    var text: String
    var toolChain: [ChatMessage.ToolInvocation]
    var onOpenArtifact: (URL) -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !toolChain.isEmpty {
                ToolChainView(invocations: toolChain, onOpenArtifact: onOpenArtifact)
            }

            if !text.isEmpty {
                MarkdownView(text: text)
            }

            if isHovering && !text.isEmpty {
                CopyButton(text: text)
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
    }
}

/// In-flight version of `AssistantMessage`: same tool chain styling,
/// plus a footer shimmer that appears only when no tool is actively
/// running. A spinning tool row already telegraphs "the agent is
/// doing something" — duplicating it with a shimmer below felt noisy
/// and pulled the eye in two directions at once. Between CLI calls
/// (or before any tool is invoked) the shimmer comes back as the
/// quiet "still here, still thinking" affordance.
private struct LiveAssistantMessage: View {
    var message: ChatMessage
    var showToolChain: Bool
    var onOpenArtifact: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showToolChain && !message.toolChain.isEmpty {
                ToolChainView(
                    invocations: message.toolChain,
                    onOpenArtifact: onOpenArtifact
                )
            }

            if !message.text.isEmpty {
                MarkdownView(text: message.text)
            }

            if showsFooterShimmer {
                HStack(spacing: 6) {
                    StreamingCursor()
                    ShimmerText(footerLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.springSnap, value: showsFooterShimmer)
    }

    /// Only one in-progress indicator at a time. If the last tool row
    /// is spinning, we let that carry the story.
    private var showsFooterShimmer: Bool {
        message.toolChain.last?.status != .running
    }

    /// Quiet, generic label — the per-row spinner above already says
    /// what we're doing when it matters. Falling back to the message's
    /// own status label keeps the door open for callers that want to
    /// override it for non-tool flows.
    private var footerLabel: String {
        message.statusLabel ?? AgentStatusLabel.thinking
    }
}

/// Pulsing white dot that sits in front of the streaming status text.
/// Same "alive" affordance as a terminal cursor — gives the live bubble
/// a heartbeat when nothing else is moving on the screen.
private struct StreamingCursor: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Palette.textPrimary)
            .frame(width: 5, height: 5)
            .opacity(on ? 1 : 0.35)
            .scaleEffect(on ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// MARK: - Tool chain

/// Vertical list of native browser tool calls the model fired off for
/// an assistant turn. Rendered as a quiet log of single-line rows —
/// status glyph, lowercase verb, faded argument. No card chrome, no
/// hover fills; the goal is to communicate "the agent is just doing
/// it" without grabbing visual focus away from the model's answer.
/// Tapping a row reveals an indented detail panel with the captured
/// input and output for that step.
private struct ToolChainView: View {
    let invocations: [ChatMessage.ToolInvocation]
    var onOpenArtifact: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(invocations.enumerated()), id: \.offset) { _, invocation in
                ToolCallRow(invocation: invocation, onOpenArtifact: onOpenArtifact)
            }
        }
    }
}

/// One row in the quiet tool log. Layout is intentionally text-first:
/// a small status glyph on the left, then `verb · arg` like a shell
/// trace. Tap to expand an indented detail panel that mirrors the old
/// card view (INPUT / OUTPUT sections), so power users can still
/// audit the full I/O when they care.
private struct ToolCallRow: View {
    let invocation: ChatMessage.ToolInvocation
    var onOpenArtifact: (URL) -> Void

    @State private var expanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
                .contentShape(Rectangle())
                .onTapGesture {
                    if isArtifactRow {
                        if let artifactURL = invocation.artifactURL {
                            onOpenArtifact(artifactURL)
                        }
                    } else if canExpand {
                        withAnimation(Motion.springSnap) { expanded.toggle() }
                    }
                }
                .onHover { hovering in
                    withAnimation(Motion.hoverFade) { isHovering = hovering }
                    if hovering && (isArtifactRow || canExpand) {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help(helpText)

            if expanded {
                detailPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -2)),
                        removal: .opacity
                    ))
            }
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ToolStatusGlyph(status: invocation.status)
                // Push the glyph down a hair so it visually sits on the
                // text baseline instead of riding above the cap height.
                .alignmentGuide(.firstTextBaseline) { _ in 8.5 }

            Text(label)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(textColor)

            if !displayInput.isEmpty {
                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textFaint)
                Text(displayInput)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isArtifactRow {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
                    .opacity(isHovering ? 1 : 0.55)
            }
        }
        .padding(.vertical, 2)
    }

    /// Active rows pop slightly brighter so the eye finds the current
    /// step. Completed rows fade to the same muted tone so the older
    /// chain stays in the background.
    private var textColor: Color {
        switch invocation.status {
        case .running:
            return Palette.textSecondary
        case .completed, .failed:
            return Palette.textMuted
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !invocation.input.isEmpty {
                detailSection(title: "INPUT", body: invocation.input, monospaced: true)
            }

            if let output = invocation.output, !output.isEmpty {
                detailSection(title: outputSectionTitle, body: output, monospaced: false)
            } else if invocation.status == .running {
                Text("Running…")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.leading, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
        // Hairline thread on the left so the panel reads as a sub-item
        // of its row rather than a free-floating block.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1)
                .padding(.leading, 4)
                .padding(.vertical, 4)
        }
    }

    private func detailSection(title: String, body: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.textFaint)

            Text(body)
                .font(.system(
                    size: 11,
                    weight: .regular,
                    design: monospaced ? .monospaced : .default
                ))
                .foregroundStyle(Palette.textMuted)
                .textSelection(.enabled)
                .lineLimit(20)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var outputSectionTitle: String {
        switch invocation.status {
        case .running: return "PARTIAL"
        case .completed: return "OUTPUT"
        case .failed: return "ERROR"
        }
    }

    private var isArtifactRow: Bool {
        invocation.tool == "create_artifact"
            && invocation.status == .completed
            && invocation.artifactURL != nil
    }

    private var canExpand: Bool {
        if isArtifactRow { return false }
        if invocation.status == .running { return true }
        return !(invocation.output?.isEmpty ?? true) || !invocation.input.isEmpty
    }

    private var label: String {
        switch invocation.tool {
        case "open": return "open"
        case "search": return "search"
        case "fetch": return "fetch"
        case "read_tabs": return "read tabs"
        case "read_highlights": return "read highlights"
        case "read_smart_read": return "read smart read"
        case "mail_search": return "mail search"
        case "mail_read_thread": return "mail read"
        case "mail_draft_reply": return "mail draft"
        case "create_artifact": return "artifact"
        case "web_control": return "web control"
        default: return invocation.tool.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Compact form of the argument for inline display: URLs collapse to
    /// their host, queries stay as-is. Falls back to the raw input.
    private var displayInput: String {
        let trimmed = invocation.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if invocation.tool == "open" || invocation.tool == "fetch" {
            if let url = URL(string: trimmed), let host = url.host(percentEncoded: false), !host.isEmpty {
                return host
            }
            if let url = URL(string: "https://\(trimmed)"), let host = url.host(percentEncoded: false), !host.isEmpty {
                return host
            }
        }
        return trimmed
    }

    private var helpText: String {
        let suffix: String
        switch invocation.status {
        case .running: suffix = " (running)"
        case .completed: suffix = ""
        case .failed: suffix = " (failed)"
        }
        return "\(invocation.tool): \(invocation.input)\(suffix)"
    }
}

/// Bare-bones status indicator for the quiet tool log: a tiny spinner
/// while running, a muted check when done, a faint slash when failed.
/// All three live in the same 9×9 footprint so the row doesn't reflow
/// width as the status changes.
private struct ToolStatusGlyph: View {
    let status: ChatMessage.ToolInvocation.Status

    var body: some View {
        ZStack {
            switch status {
            case .running:
                ToolSpinner()
            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: 9, height: 9)
    }
}

private struct ToolSpinner: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.72)
            .stroke(Palette.textSecondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .overlay {
                Capsule().stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(Motion.springSnap) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

private struct SystemPill: View {
    var text: String

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().stroke(Palette.strokeStrong, lineWidth: 1))
            Spacer()
        }
    }
}

// MARK: - Thinking indicator

private struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -0.4

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.textFaint)
            .overlay {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase - 0.25)),
                                .init(color: Palette.textPrimary, location: max(0, min(1, phase))),
                                .init(color: .clear, location: min(1, phase + 0.25))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .mask {
                        Text(text)
                            .font(.system(size: 13, weight: .medium))
                    }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }
}

private struct BreathingPulse: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.25 : 0.85)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// MARK: - Model picker button

private struct ModelPickerButton: View {
    let provider: AIProviderKind
    @Binding var showingPicker: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            showingPicker.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(isHovering || showingPicker ? Palette.surfaceHover : Palette.surface)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(isHovering || showingPicker ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
                    .frame(width: 32, height: 32)
                ProviderMark(provider: provider, size: 14)
                    .foregroundStyle(Palette.textPrimary)
            }
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(Motion.springSnap, value: isHovering)
            .animation(Motion.hoverFade, value: showingPicker)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose model")
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            ModelPickerPopover {
                showingPicker = false
            }
        }
    }
}

// MARK: - Send button

private struct SendButton: View {
    var enabled: Bool
    var sending: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(buttonFill)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(enabled ? Color.clear : Palette.stroke, lineWidth: 1)
                    .frame(width: 32, height: 32)

                if sending {
                    SpinnerArc()
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(enabled ? Palette.bg : Palette.textMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .scaleEffect(scaleValue)
            .shadow(color: enabled && !sending && isHovering ? Color.white.opacity(0.20) : Color.clear, radius: 10, x: 0, y: 0)
            .animation(Motion.springSnap, value: isHovering)
            .animation(Motion.springSnap, value: enabled)
            .animation(.easeOut(duration: 0.18), value: sending)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || sending)
        .onHover { isHovering = $0 }
        .help("Send")
    }

    private var scaleValue: CGFloat {
        if !enabled { return 1 }
        return isHovering ? 1.06 : 1
    }

    private var buttonFill: Color {
        if !enabled { return Palette.surface }
        if sending { return Palette.surfaceActive }
        return Palette.accent
    }
}

private struct SpinnerArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// Counterpart to `SendButton` that takes over the composer's primary
/// action while the agent loop is running. Surfaces a stop glyph
/// wrapped in a faint spinner so the user reads it as "in progress —
/// click to interrupt" rather than as a regular button.
private struct StopButton: View {
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(Palette.strokeStrong, lineWidth: 1)
                    .frame(width: 32, height: 32)
                SpinnerArc()
                    .opacity(0.55)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.textPrimary)
                    .frame(width: 9, height: 9)
            }
            .scaleEffect(isHovering ? 1.06 : 1.0)
            .shadow(color: isHovering ? Color.white.opacity(0.18) : Color.clear, radius: 9, x: 0, y: 0)
            .animation(Motion.springSnap, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Stop")
    }
}

// MARK: - Draft preset bar

/// Horizontal row of preset chips shown above the composer once the user
/// has hit "Draft" in the cited clipboard popover. Picking a chip stages
/// the preset's drafting rubric for the next send; the X chip exits draft
/// mode without sending.
private struct DraftPresetBar: View {
    let selected: CitedClipDraftPreset
    var onPick: (CitedClipDraftPreset) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                Text("Drafting")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textFaint)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Exit draft mode")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CitedClipDraftPreset.allCases) { preset in
                        DraftPresetChip(
                            preset: preset,
                            isSelected: preset == selected,
                            action: { onPick(preset) }
                        )
                    }
                }
            }
        }
    }
}

private struct DraftPresetChip: View {
    let preset: CitedClipDraftPreset
    let isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(preset.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Palette.bg : Palette.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                Capsule().fill(chipFill)
            }
            .overlay {
                Capsule().stroke(isSelected ? Palette.accent : Palette.stroke, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(preset.subtitle)
    }

    private var chipFill: Color {
        if isSelected { return Palette.accent }
        if isHovering { return Palette.surfaceHover }
        return Palette.surface
    }
}
