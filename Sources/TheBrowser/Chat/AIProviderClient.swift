import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var assistantDescription: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .claude:
            return "Claude CLI"
        }
    }

    var availableModels: [AIModelOption] {
        switch self {
        case .codex:
            return [
                AIModelOption(provider: .codex, modelID: "gpt-5.5", displayName: "GPT-5.5"),
                AIModelOption(provider: .codex, modelID: "gpt-5.4", displayName: "GPT-5.4"),
                AIModelOption(provider: .codex, modelID: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
                AIModelOption(provider: .codex, modelID: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
                AIModelOption(provider: .codex, modelID: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark"),
                AIModelOption(provider: .codex, modelID: "gpt-5.2", displayName: "GPT-5.2")
            ]
        case .claude:
            return [
                AIModelOption(provider: .claude, modelID: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
                AIModelOption(provider: .claude, modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
                AIModelOption(provider: .claude, modelID: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
                AIModelOption(provider: .claude, modelID: "claude-opus-4-6", displayName: "Claude Opus 4.6")
            ]
        }
    }

    /// Lightweight, low-latency model id used for ad-hoc background tasks
    /// (e.g. the inline AI answer above search results). Cheaper and faster
    /// than the user's primary chat model so the summary card lands quickly.
    var fastModelID: String {
        switch self {
        case .claude: return "claude-haiku-4-5"
        case .codex: return "gpt-5.4-mini"
        }
    }
}

struct AIModelOption: Identifiable, Hashable, Sendable {
    let provider: AIProviderKind
    let modelID: String
    let displayName: String

    var id: String { "\(provider.rawValue):\(modelID)" }
}

extension AIModelOption {
    static var all: [AIModelOption] {
        AIProviderKind.allCases.flatMap(\.availableModels)
    }

    static func find(id: String) -> AIModelOption? {
        all.first(where: { $0.id == id })
    }

    static func find(provider: AIProviderKind, modelID: String) -> AIModelOption? {
        provider.availableModels.first(where: { $0.modelID == modelID })
    }
}

enum AIProviderError: LocalizedError {
    case missingExecutable(provider: AIProviderKind, path: String)
    case processFailed(provider: AIProviderKind, status: Int32, output: String)
    case emptyResponse
    /// User pressed Stop. Distinguished from a generic failure so the
    /// chat surface can render a quiet "Stopped" pill instead of an
    /// error banner.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let provider, let path):
            return "\(provider.assistantDescription) was not found at \(path). Open Settings and choose the CLI path."
        case .processFailed(let provider, let status, let output):
            return "\(provider.displayName) exited with status \(status).\n\(output)"
        case .emptyResponse:
            return "The selected AI provider finished without returning a message."
        case .cancelled:
            return "Stopped."
        }
    }
}

struct AIHarnessConfiguration: Sendable {
    var provider: AIProviderKind
    var cliPath: String
    var workspacePath: String
    var model: String
    var sandbox: String
    var systemPrompt: String
    var tools: String
    var allowedTools: String
    var disallowedTools: String
    var mcpConfigPath: String
    var extraArguments: String
    var reasoningEffort: String

    /// True when the configured provider+model combo supports the
    /// stream-json event protocol the live chat loop uses for partial
    /// text rendering. Codex's `exec` mode doesn't emit per-token deltas
    /// over stdout, so we keep it on the legacy single-response path.
    var supportsStreamingEvents: Bool {
        provider == .claude
    }

    static func current(defaults: UserDefaults = .standard) -> AIHarnessConfiguration {
        let provider = AIProviderKind(rawValue: defaults.string(forKey: PreferenceKey.aiProvider) ?? "") ?? .codex
        let cliPath: String

        switch provider {
        case .codex:
            cliPath = defaults.string(forKey: PreferenceKey.codexCLIPath) ?? AppDefaults.defaultCodexCLIPath()
        case .claude:
            cliPath = defaults.string(forKey: PreferenceKey.claudeCLIPath) ?? AppDefaults.defaultClaudeCLIPath()
        }

        let workspacePath = defaults.persistedString(forKey: PreferenceKey.aiWorkspacePath)
            ?? defaults.persistedString(forKey: PreferenceKey.codexWorkspacePath)
            ?? AppDefaults.defaultWorkspacePath()
        let model = defaults.persistedString(forKey: PreferenceKey.aiModel)
            ?? defaults.persistedString(forKey: PreferenceKey.codexModel)
            ?? ""
        let sandbox = defaults.string(forKey: PreferenceKey.codexSandbox) ?? "read-only"

        return AIHarnessConfiguration(
            provider: provider,
            cliPath: cliPath,
            workspacePath: workspacePath,
            model: model,
            sandbox: sandbox,
            systemPrompt: defaults.string(forKey: PreferenceKey.aiSystemPrompt) ?? AppDefaults.defaultAISystemPrompt,
            tools: defaults.string(forKey: PreferenceKey.aiTools) ?? "",
            allowedTools: defaults.string(forKey: PreferenceKey.aiAllowedTools) ?? "",
            disallowedTools: defaults.string(forKey: PreferenceKey.aiDisallowedTools) ?? "",
            mcpConfigPath: defaults.string(forKey: PreferenceKey.aiMCPConfigPath) ?? "",
            extraArguments: defaults.string(forKey: PreferenceKey.aiExtraArguments) ?? "",
            reasoningEffort: ""
        )
    }
}

extension AIHarnessConfiguration {
    var promptIdentity: String {
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName: String
        let modelIDLabel: String

        if modelID.isEmpty {
            modelName = "Not explicitly configured"
            modelIDLabel = "not explicitly configured"
        } else {
            modelName = AIModelOption.find(provider: provider, modelID: modelID)?.displayName ?? modelID
            modelIDLabel = modelID
        }

        return """
        AI runtime:
        Provider: \(provider.displayName)
        Model: \(modelName)
        Model ID: \(modelIDLabel)
        If the user asks what model you are, answer using the Provider, Model, and Model ID above. If the model is not explicitly configured, say so instead of guessing.
        """
    }
}

struct AIProviderClient {
    func ask(
        _ message: String,
        context: BrowserPageContext,
        sessionDirectory: URL,
        history: [ChatMessage] = [],
        tabs: [TabManifestEntry] = []
    ) async throws -> String {
        let configuration = AIHarnessConfiguration.current()
        let prompt = Self.prompt(
            for: message,
            context: context,
            history: history,
            configuration: configuration,
            tabs: tabs
        )
        return try await ask(prompt: prompt, sessionDirectory: sessionDirectory)
    }

    /// Streams events from the provider CLI in real time. Claude emits
    /// per-token text deltas; Codex (and any future non-stream provider)
    /// folds into a single `.result` event at the end. The chat loop
    /// consumes this stream to update the in-flight assistant bubble
    /// character-by-character as text arrives.
    func askStream(
        prompt: String,
        sessionDirectory: URL? = nil,
        runHandle: AgentRunHandle? = nil
    ) -> AsyncThrowingStream<HarnessEvent, Error> {
        var configuration = AIHarnessConfiguration.current()
        if let sessionDirectory {
            configuration.workspacePath = sessionDirectory.path
        }
        let resolvedConfig = configuration

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let text = try runProviderStreaming(
                        configuration: resolvedConfig,
                        prompt: prompt,
                        runHandle: runHandle,
                        onEvent: { event in
                            continuation.yield(event)
                        }
                    )
                    // Always end with a final `.result` so the consumer
                    // can rely on a single authoritative payload (and
                    // ignore the partial accumulated text if needed).
                    continuation.yield(.result(text: text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Single-shot CLI call with no chat history or session persistence. Used
    /// by ad-hoc features (e.g. inline AI answers above search results) that
    /// just need a prompt → response round trip. The optional overrides let
    /// callers swap the user's chat persona / model for a task-specific
    /// choice without mutating saved settings. The optional `runHandle`
    /// is what the live agent loop uses to terminate the CLI process if
    /// the user presses Stop.
    func ask(
        prompt: String,
        sessionDirectory: URL? = nil,
        systemPromptOverride: String? = nil,
        modelOverride: String? = nil,
        reasoningEffortOverride: String? = nil,
        runHandle: AgentRunHandle? = nil
    ) async throws -> String {
        var configuration = AIHarnessConfiguration.current()
        if let sessionDirectory {
            // Force chat CLI calls to run inside the session directory so
            // each conversation is isolated under ~/.thebrowser/sessions/<id>.
            configuration.workspacePath = sessionDirectory.path
        }
        if let systemPromptOverride {
            configuration.systemPrompt = systemPromptOverride
        }
        if let modelOverride {
            configuration.model = modelOverride
        }
        if let reasoningEffortOverride {
            configuration.reasoningEffort = reasoningEffortOverride
        }

        let resolvedConfig = configuration
        return try await Task.detached(priority: .userInitiated) {
            try runProvider(configuration: resolvedConfig, prompt: prompt, runHandle: runHandle)
        }.value
    }

    /// One-shot completion pinned to an explicit provider + model, independent
    /// of the user's chat settings. The Mail sub-agent uses this so it can run
    /// on a fast model (and optionally a different provider) without mutating
    /// saved preferences. Runs read-only in `workspace` with no native/MCP
    /// tools — it's a pure prompt → text round trip.
    func complete(
        prompt: String,
        provider: AIProviderKind,
        model: String,
        systemPrompt: String? = nil,
        workspace: URL? = nil,
        reasoningEffort: String = "",
        runHandle: AgentRunHandle? = nil
    ) async throws -> String {
        var configuration = AIHarnessConfiguration.current()
        configuration.provider = provider
        switch provider {
        case .codex:
            configuration.cliPath = UserDefaults.standard.string(forKey: PreferenceKey.codexCLIPath)
                ?? AppDefaults.defaultCodexCLIPath()
        case .claude:
            configuration.cliPath = UserDefaults.standard.string(forKey: PreferenceKey.claudeCLIPath)
                ?? AppDefaults.defaultClaudeCLIPath()
        }
        configuration.model = model
        configuration.sandbox = "read-only"
        configuration.reasoningEffort = reasoningEffort
        configuration.tools = ""
        configuration.allowedTools = ""
        configuration.disallowedTools = ""
        configuration.mcpConfigPath = ""
        configuration.extraArguments = ""
        if let systemPrompt { configuration.systemPrompt = systemPrompt }
        if let workspace { configuration.workspacePath = workspace.path }

        let resolved = configuration
        return try await Task.detached(priority: .userInitiated) {
            try runProvider(configuration: resolved, prompt: prompt, runHandle: runHandle)
        }.value
    }

    static func prompt(
        for message: String,
        context: BrowserPageContext,
        history: [ChatMessage] = [],
        configuration: AIHarnessConfiguration? = nil,
        tabs: [TabManifestEntry] = [],
        attachments: [ChatAttachment] = [],
        smartReadActive: Bool = false,
        mailContext: String? = nil
    ) -> String {
        let pageURL = context.url.isEmpty ? "Home page" : context.url

        // Build the conversation-wide global numbering for every attachment
        // ever sent. The current user message has already been appended to
        // `history` at this point (so it includes its own attachments) and
        // the same `attachments` array is mirrored here for the inline
        // "this-turn highlights" block. Walking history once gives us
        // stable 1-based indices that match `ChatViewModel.collectAttachments`.
        struct NumberedAttachment {
            var index: Int
            var messageID: ChatMessage.ID
            var attachment: ChatAttachment
        }
        var globalAttachments: [NumberedAttachment] = []
        var counter = 0
        for msg in history where msg.role == .user {
            for att in msg.attachments {
                counter += 1
                globalAttachments.append(NumberedAttachment(index: counter, messageID: msg.id, attachment: att))
            }
        }
        let currentMessageID = history.last(where: { $0.role == .user })?.id

        // Conversation history excludes the user message just appended (it
        // becomes the explicit "User request" below) and any system rows
        // (those are local error notices, not part of the dialogue).
        let priorTurns = history.dropLast().filter { $0.role != .system }

        var transcript = ""
        if !priorTurns.isEmpty {
            transcript = "Conversation so far:\n"
            for msg in priorTurns {
                let label = msg.role == .user ? "User" : "Assistant"
                if msg.role == .user, !msg.attachments.isEmpty {
                    let indices = globalAttachments
                        .filter { $0.messageID == msg.id }
                        .map { "[\($0.index)]" }
                        .joined(separator: ", ")
                    transcript += "\(label) (with highlights \(indices)): \(msg.text)\n"
                } else {
                    transcript += "\(label): \(msg.text)\n"
                }
            }
            transcript += "\n"
        }

        var tabsBlock = ""
        if !tabs.isEmpty {
            var lines: [String] = ["Open tabs:"]
            for entry in tabs {
                let marker = entry.isSelected ? "*" : " "
                let url = entry.url.isEmpty ? "(home)" : entry.url
                lines.append("  \(marker) \(entry.index). \(entry.title) — \(url)")
            }
            lines.append("(* = currently selected. Use read_tabs to read the visible text of one or more of these tabs.)")
            tabsBlock = lines.joined(separator: "\n") + "\n\n"
        }

        // Prior-turn highlights surface as a compact manifest (index +
        // source + short preview) so the model knows they exist without
        // paying for their full content on every turn. To read the full
        // text it must call read_highlights.
        let priorNumbered = globalAttachments.filter { $0.messageID != currentMessageID }
        var priorManifestBlock = ""
        if !priorNumbered.isEmpty {
            var lines: [String] = ["Highlights previously attached in this conversation (call read_highlights with the desired index to retrieve the full text):"]
            for item in priorNumbered {
                let att = item.attachment
                let label = att.displayLabel
                let host = att.host ?? ""
                let preview = att.preview
                let trimmedPreview = preview.count > 90 ? String(preview.prefix(90)) + "…" : preview
                let suffix = host.isEmpty || host == label ? "" : " (\(host))"
                lines.append("[\(item.index)] \(label)\(suffix) — \(trimmedPreview)")
            }
            priorManifestBlock = lines.joined(separator: "\n") + "\n\n"
        }

        // Current turn's highlights are inlined in full so the model can
        // act on them immediately, using the same global indices the
        // manifest exposes (so [4] in the inline block is the same [4]
        // the model would later fetch via read_highlights).
        let currentNumbered = globalAttachments.filter { $0.messageID == currentMessageID }
        var currentAttachmentsBlock = ""
        if !attachments.isEmpty {
            var lines: [String] = ["Highlighted passages the user attached for this turn:"]
            // Pair each passed-in attachment with its global index. If a
            // numbering entry isn't found (shouldn't happen when called
            // from ChatViewModel.send), fall back to the local 1-based
            // order so the prompt still renders sensibly.
            for (offset, attachment) in attachments.enumerated() {
                let resolvedIndex = currentNumbered.first(where: { $0.attachment.id == attachment.id })?.index
                    ?? (counter - attachments.count + offset + 1)
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
                lines.append("[\(resolvedIndex)] From \(source):")
                for piece in attachment.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(piece)")
                }
            }
            lines.append("(Treat these passages as authoritative quotations from the cited sources. Refer to them by their bracketed index when relevant.)")
            currentAttachmentsBlock = lines.joined(separator: "\n") + "\n\n"
        }

        let smartReadBlock = smartReadActive
            ? "Smart Read: a summary of the current page is displayed in the chat sidebar. Call read_smart_read to retrieve its TL;DR, key points, and metadata when the user references it.\n\n"
            : ""

        let mailContextBlock = mailContext.map { "\($0)\n\n" } ?? ""

        return """
        \(NativeBrowserToolPrompt.instructions)

        \(configuration?.promptIdentity ?? "")

        \(tabsBlock)Current tab:
        Title: \(context.title)
        URL: \(pageURL)

        \(mailContextBlock)\(smartReadBlock)\(priorManifestBlock)\(currentAttachmentsBlock)\(transcript)User request:
        \(message)
        """
    }
}

/// Streaming counterpart to `runProvider`. For Claude this pipes stdout
/// through an NDJSON parser and forwards text deltas + the final result.
/// For Codex (no native streaming) it delegates to the legacy file-based
/// runner and emits a single `.textDelta` containing the full body — the
/// chat loop still gets a "result arrived" trigger but the bubble fills
/// in one chunk.
private func runProviderStreaming(
    configuration: AIHarnessConfiguration,
    prompt: String,
    runHandle: AgentRunHandle?,
    onEvent: @escaping @Sendable (HarnessEvent) -> Void
) throws -> String {
    switch configuration.provider {
    case .claude:
        return try runClaudeStreaming(
            configuration: configuration,
            prompt: prompt,
            runHandle: runHandle,
            onEvent: onEvent
        )
    case .codex:
        // No native event stream — fall back to the legacy single-shot
        // path. The final response surfaces in one `.textDelta` so the
        // chat loop's accumulator picks it up exactly once.
        let response = try runProvider(
            configuration: configuration,
            prompt: prompt,
            runHandle: runHandle
        )
        if !response.isEmpty {
            onEvent(.textDelta(response))
        }
        return response
    }
}

/// Runs Claude with `--output-format stream-json --include-partial-messages`
/// and parses each NDJSON line into a `HarnessEvent`. Text deltas are
/// forwarded immediately; the final `result` event captures the
/// authoritative full body. Cancellation kills the subprocess so the
/// reader loop exits on its next read.
private func runClaudeStreaming(
    configuration: AIHarnessConfiguration,
    prompt: String,
    runHandle: AgentRunHandle?,
    onEvent: @escaping @Sendable (HarnessEvent) -> Void
) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: configuration.cliPath) else {
        throw AIProviderError.missingExecutable(provider: .claude, path: configuration.cliPath)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.cliPath)
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe
    process.currentDirectoryURL = URL(fileURLWithPath: configuration.workspacePath, isDirectory: true)
    process.arguments = CLIArguments.claudeStreamingArguments(for: configuration)

    let parser = ClaudeStreamParser(onEvent: onEvent)
    let stdoutHandle = stdoutPipe.fileHandleForReading
    stdoutHandle.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            // EOF — the run loop will exit, parser keeps any pending
            // tail-text for the final answer.
            handle.readabilityHandler = nil
            return
        }
        parser.append(data)
    }

    try process.run()
    runHandle?.attach(process: process)

    // Pipe the prompt into the subprocess and close stdin so Claude
    // knows the user's turn is complete and starts producing output.
    stdinPipe.fileHandleForWriting.write(Data(prompt.utf8))
    try? stdinPipe.fileHandleForWriting.close()

    process.waitUntilExit()
    runHandle?.detach()

    // Drain anything still sitting in the pipe after the process exits;
    // the readability handler may not have fired on the trailing bytes.
    stdoutHandle.readabilityHandler = nil
    let trailingData = try? stdoutHandle.readToEnd()
    if let trailingData, !trailingData.isEmpty {
        parser.append(trailingData)
    }
    let stderrText = (try? stderrPipe.fileHandleForReading.readToEnd())
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""

    if runHandle?.isCancelled == true {
        throw AIProviderError.cancelled
    }

    guard process.terminationStatus == 0 else {
        let detail = [stderrText, parser.accumulatedText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw AIProviderError.processFailed(provider: .claude, status: process.terminationStatus, output: detail)
    }

    let finalText = parser.finalText
    if finalText.isEmpty {
        throw AIProviderError.emptyResponse
    }
    return finalText
}

private func runProvider(
    configuration: AIHarnessConfiguration,
    prompt: String,
    runHandle: AgentRunHandle? = nil
) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: configuration.cliPath) else {
        throw AIProviderError.missingExecutable(provider: configuration.provider, path: configuration.cliPath)
    }

    let tempDirectory = FileManager.default.temporaryDirectory
    let outputURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-\(UUID().uuidString).txt")
    let stdoutURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-stdout-\(UUID().uuidString).log")
    let stderrURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-stderr-\(UUID().uuidString).log")
    let systemPromptFileURL = try systemPromptFileIfNeeded(for: configuration, in: tempDirectory)

    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    defer {
        try? FileManager.default.removeItem(at: outputURL)
        if let systemPromptFileURL {
            try? FileManager.default.removeItem(at: systemPromptFileURL)
        }
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.cliPath)
    process.standardOutput = stdout
    process.standardError = stderr
    let standardInputData = CLIArguments.standardInputData(for: configuration, prompt: prompt)
    let stdin = standardInputData == nil ? nil : Pipe()
    if let stdin {
        process.standardInput = stdin
    }
    process.currentDirectoryURL = URL(fileURLWithPath: configuration.workspacePath, isDirectory: true)
    process.arguments = CLIArguments.arguments(
        for: configuration,
        prompt: prompt,
        outputURL: outputURL,
        systemPromptFileURL: systemPromptFileURL
    )

    try process.run()
    // Hand the run handle a reference to the subprocess immediately
    // after spawn so a Stop press mid-call can terminate it. If the
    // handle was already cancelled before we got here, `attach` will
    // call `terminate()` synchronously and the wait below returns fast.
    runHandle?.attach(process: process)
    if let standardInputData, let stdin {
        stdin.fileHandleForWriting.write(standardInputData)
        try? stdin.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    runHandle?.detach()

    try stdout.close()
    try stderr.close()

    if runHandle?.isCancelled == true {
        throw AIProviderError.cancelled
    }

    let finalMessage = (try? String(contentsOf: outputURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

    guard process.terminationStatus == 0 else {
        let providerOutput: String
        if configuration.provider == .claude,
           let result = ClaudeJSONResponse.result(from: stdoutText) {
            providerOutput = [stderrText.trimmingCharacters(in: .whitespacesAndNewlines), result]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            providerOutput = [stderrText, stdoutText].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        throw AIProviderError.processFailed(provider: configuration.provider, status: process.terminationStatus, output: providerOutput)
    }

    if configuration.provider == .codex, let finalMessage, !finalMessage.isEmpty {
        return finalMessage
    }

    let fallback = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty {
        if configuration.provider == .claude, let result = ClaudeJSONResponse.result(from: fallback) {
            return result
        }

        return fallback
    }

    throw AIProviderError.emptyResponse
}

private func systemPromptFileIfNeeded(for configuration: AIHarnessConfiguration, in directory: URL) throws -> URL? {
    guard configuration.provider == .codex else { return nil }

    let url = directory.appendingPathComponent("thebrowser-codex-system-\(UUID().uuidString).md")
    try CLIArguments.effectiveSystemPrompt(for: configuration).write(to: url, atomically: true, encoding: .utf8)
    return url
}

enum CLIArguments {
    private static let codexDisabledHarnessFeatures = [
        "apps",
        "browser_use",
        "browser_use_external",
        "computer_use",
        "image_generation",
        "in_app_browser",
        "multi_agent",
        "plugins",
        "shell_tool",
        "tool_search",
        "tool_suggest",
        "unified_exec",
        "workspace_dependencies"
    ]

    static func arguments(
        for configuration: AIHarnessConfiguration,
        prompt: String,
        outputURL: URL,
        systemPromptFileURL: URL? = nil
    ) -> [String] {
        switch configuration.provider {
        case .codex:
            return codexArguments(
                for: configuration,
                prompt: prompt,
                outputURL: outputURL,
                systemPromptFileURL: systemPromptFileURL
            )
        case .claude:
            return claudeArguments(for: configuration, prompt: prompt)
        }
    }

    static func codexArguments(
        for configuration: AIHarnessConfiguration,
        prompt: String,
        outputURL: URL,
        systemPromptFileURL: URL? = nil
    ) -> [String] {
        var arguments = [
            "exec",
            "--color", "never",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--sandbox", configuration.sandbox
        ]

        appendModel(configuration.model, to: &arguments)
        appendCodexReasoningEffort(configuration.reasoningEffort, to: &arguments)
        arguments.append(contentsOf: extraArguments(from: configuration.extraArguments))

        for feature in codexDisabledHarnessFeatures {
            arguments.append(contentsOf: ["--disable", feature])
        }

        if let systemPromptFileURL {
            appendConfigOverride("model_instructions_file", stringValue: systemPromptFileURL.path, to: &arguments)
        }

        appendConfigOverride("include_permissions_instructions", boolValue: false, to: &arguments)
        appendConfigOverride("include_apps_instructions", boolValue: false, to: &arguments)
        appendConfigOverride("include_environment_context", boolValue: false, to: &arguments)
        appendConfigOverride("skills.include_instructions", boolValue: false, to: &arguments)
        appendConfigOverride("include_apply_patch_tool", boolValue: false, to: &arguments)

        arguments.append(contentsOf: [
            "-C", configuration.workspacePath,
            "-o", outputURL.path,
            prompt
        ])

        return arguments
    }

    static func claudeArguments(for configuration: AIHarnessConfiguration, prompt: String) -> [String] {
        var arguments = [
            "--print",
            "--input-format", "text",
            "--output-format", "json",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-chrome"
        ]

        appendModel(configuration.model, to: &arguments)
        appendOptionalFlag("--effort", value: configuration.reasoningEffort, to: &arguments)
        arguments.append(contentsOf: extraArguments(from: configuration.extraArguments))

        arguments.append(contentsOf: ["--system-prompt", effectiveSystemPrompt(for: configuration)])
        arguments.append(contentsOf: ["--tools", trimmed(configuration.tools)])

        appendOptionalFlag("--allowedTools", value: configuration.allowedTools, to: &arguments)
        appendOptionalFlag("--disallowedTools", value: configuration.disallowedTools, to: &arguments)
        appendOptionalFlag("--mcp-config", value: configuration.mcpConfigPath, to: &arguments)

        return arguments
    }

    /// Same as `claudeArguments` but flips `--output-format` to
    /// `stream-json` and enables partial-message events so the chat loop
    /// can render text deltas in real time. `--verbose` is required for
    /// stream-json to actually emit per-event records. The prompt itself
    /// is delivered over stdin (same as the non-streaming path), so we
    /// don't append it to the argument list.
    static func claudeStreamingArguments(for configuration: AIHarnessConfiguration) -> [String] {
        var arguments = [
            "--print",
            "--input-format", "text",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-chrome"
        ]

        appendModel(configuration.model, to: &arguments)
        appendOptionalFlag("--effort", value: configuration.reasoningEffort, to: &arguments)
        arguments.append(contentsOf: extraArguments(from: configuration.extraArguments))

        arguments.append(contentsOf: ["--system-prompt", effectiveSystemPrompt(for: configuration)])
        arguments.append(contentsOf: ["--tools", trimmed(configuration.tools)])

        appendOptionalFlag("--allowedTools", value: configuration.allowedTools, to: &arguments)
        appendOptionalFlag("--disallowedTools", value: configuration.disallowedTools, to: &arguments)
        appendOptionalFlag("--mcp-config", value: configuration.mcpConfigPath, to: &arguments)

        return arguments
    }

    static func standardInputData(for configuration: AIHarnessConfiguration, prompt: String) -> Data? {
        switch configuration.provider {
        case .claude:
            return Data(prompt.utf8)
        case .codex:
            return nil
        }
    }

    /// Builds the replacement prompt sent to the underlying CLI. It is exactly
    /// the user's configured prompt after whitespace trim: no provider identity,
    /// harness banner, model name, tool list, date, or local config context.
    static func effectiveSystemPrompt(for configuration: AIHarnessConfiguration) -> String {
        trimmed(configuration.systemPrompt)
    }

    static func appendModel(_ model: String, to arguments: inout [String]) {
        let model = trimmed(model)
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
    }

    static func appendCodexReasoningEffort(_ effort: String, to arguments: inout [String]) {
        let effort = trimmed(effort)
        if !effort.isEmpty {
            appendConfigOverride("model_reasoning_effort", stringValue: effort, to: &arguments)
        }
    }

    static func appendOptionalFlag(_ flag: String, value: String, to arguments: inout [String]) {
        let value = trimmed(value)
        if !value.isEmpty {
            arguments.append(contentsOf: [flag, value])
        }
    }

    static func appendConfigOverride(_ key: String, boolValue: Bool, to arguments: inout [String]) {
        arguments.append(contentsOf: ["-c", "\(key)=\(boolValue ? "true" : "false")"])
    }

    static func appendConfigOverride(_ key: String, stringValue: String, to arguments: inout [String]) {
        arguments.append(contentsOf: ["-c", "\(key)=\(tomlStringLiteral(stringValue))"])
    }

    static func tomlStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func extraArguments(from value: String) -> [String] {
        value
            .components(separatedBy: .newlines)
            .map(trimmed)
            .filter { !$0.isEmpty }
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClaudeJSONResponse: Decodable {
    var result: String?

    static func result(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(ClaudeJSONResponse.self, from: data),
              let result = response.result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty
        else {
            return nil
        }

        return result
    }
}

/// Stateful NDJSON parser for Claude's `--output-format stream-json`
/// output. Maintains a rolling byte buffer; whenever a complete newline-
/// terminated event arrives it's decoded as JSON and inspected for the
/// two records the chat loop cares about:
///   - `stream_event.content_block_delta` with a `text_delta` payload —
///     yielded as a `.textDelta` so the live bubble fills in
///     character-by-character.
///   - `result.subtype=="success"` — captured as the authoritative final
///     body; surfaces via `finalText`.
///
/// All other event types (system init, rate limits, tool use,
/// message_start/stop, assistant aggregates) are intentionally ignored
/// — we don't need them for our pseudo-tool architecture and surfacing
/// them would bloat the harness without unlocking real UX.
final class ClaudeStreamParser: @unchecked Sendable {
    private let onEvent: @Sendable (HarnessEvent) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var _accumulatedText = ""
    private var _finalResult: String?

    init(onEvent: @escaping @Sendable (HarnessEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Raw text we've seen pass through `text_delta` events so far. Used
    /// as a fallback when the final `result` event is absent (e.g. when
    /// Claude exits non-zero halfway through producing output).
    var accumulatedText: String {
        lock.lock(); defer { lock.unlock() }
        return _accumulatedText
    }

    /// Authoritative final body: prefers `result.result` when seen,
    /// otherwise falls back to the concatenation of streamed text
    /// deltas. Trimmed of leading/trailing whitespace.
    var finalText: String {
        lock.lock(); defer { lock.unlock() }
        let candidate = _finalResult ?? _accumulatedText
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Feeds more bytes into the parser. Splits the buffer on newlines
    /// and decodes each complete line as an independent JSON object,
    /// holding any trailing partial line for the next call.
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<newlineIndex)
            buffer.removeSubrange(0...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return }

        let type = dictionary["type"] as? String ?? ""

        switch type {
        case "stream_event":
            handleStreamEvent(dictionary)
        case "assistant":
            // Final aggregated message — capture its text for the
            // fallback path. We don't yield from here because the
            // text_delta events already populated the live bubble.
            captureAssistantMessage(dictionary)
        case "result":
            handleResult(dictionary)
        default:
            // `system`, `user`, `rate_limit_event`, …
            break
        }
    }

    private func handleStreamEvent(_ dictionary: [String: Any]) {
        guard let event = dictionary["event"] as? [String: Any] else { return }
        let eventType = event["type"] as? String ?? ""
        guard eventType == "content_block_delta" else { return }
        guard let delta = event["delta"] as? [String: Any] else { return }
        let deltaType = delta["type"] as? String ?? ""
        guard deltaType == "text_delta",
              let text = delta["text"] as? String,
              !text.isEmpty
        else { return }

        _accumulatedText += text
        onEvent(.textDelta(text))
    }

    private func captureAssistantMessage(_ dictionary: [String: Any]) {
        guard let message = dictionary["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }

        var aggregated = ""
        for block in content {
            if (block["type"] as? String) == "text",
               let text = block["text"] as? String {
                aggregated += text
            }
        }
        if !aggregated.isEmpty && _finalResult == nil {
            // Keep this as a fallback; result event takes precedence if
            // it arrives later.
            _finalResult = aggregated
        }
    }

    private func handleResult(_ dictionary: [String: Any]) {
        guard let result = dictionary["result"] as? String else { return }
        _finalResult = result
    }
}

private extension UserDefaults {
    func persistedString(forKey key: String) -> String? {
        object(forKey: key) as? String
    }
}
