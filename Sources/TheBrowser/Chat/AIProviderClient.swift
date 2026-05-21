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
    case invalidMCPConfig(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let provider, let path):
            return "\(provider.assistantDescription) was not found at \(path). Open Settings and choose the CLI path."
        case .processFailed(let provider, let status, let output):
            return "\(provider.displayName) exited with status \(status).\n\(output)"
        case .emptyResponse:
            return "The selected AI provider finished without returning a message."
        case .invalidMCPConfig(let path, let reason):
            return "The MCP config at \(path) could not be loaded: \(reason)"
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
    var scopedFilesystemRoot: String?

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
            reasoningEffort: "",
            scopedFilesystemRoot: nil
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

    /// Single-shot CLI call with no chat history or session persistence. Used
    /// by ad-hoc features (e.g. inline AI answers above search results) that
    /// just need a prompt → response round trip. The optional overrides let
    /// callers swap the user's chat persona / model for a task-specific
    /// choice without mutating saved settings.
    func ask(
        prompt: String,
        sessionDirectory: URL? = nil,
        systemPromptOverride: String? = nil,
        modelOverride: String? = nil,
        reasoningEffortOverride: String? = nil
    ) async throws -> String {
        var configuration = AIHarnessConfiguration.current()
        if let sessionDirectory {
            // Force chat CLI calls into the supplied working directory and
            // scope the MCP filesystem server to that same root.
            configuration.workspacePath = sessionDirectory.path
            configuration.scopedFilesystemRoot = sessionDirectory.path
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
            try runProvider(configuration: resolvedConfig, prompt: prompt)
        }.value
    }

    static func prompt(
        for message: String,
        context: BrowserPageContext,
        history: [ChatMessage] = [],
        configuration: AIHarnessConfiguration? = nil,
        tabs: [TabManifestEntry] = [],
        attachments: [ChatAttachment] = [],
        smartReadActive: Bool = false
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

        return """
        \(NativeBrowserToolPrompt.instructions)

        \(configuration?.promptIdentity ?? "")

        \(tabsBlock)Current tab:
        Title: \(context.title)
        URL: \(pageURL)

        \(smartReadBlock)\(priorManifestBlock)\(currentAttachmentsBlock)\(transcript)User request:
        \(message)
        """
    }
}

private func runProvider(configuration: AIHarnessConfiguration, prompt: String) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: configuration.cliPath) else {
        throw AIProviderError.missingExecutable(provider: configuration.provider, path: configuration.cliPath)
    }

    let tempDirectory = FileManager.default.temporaryDirectory
    var runtimeConfiguration = configuration
    let scopedMCPConfigURL: URL?
    if configuration.provider == .claude, let scopedFilesystemRoot = configuration.scopedFilesystemRoot {
        let scratchDirectory = URL(fileURLWithPath: scopedFilesystemRoot, isDirectory: true)
        let generatedMCPConfigURL = try scopedMCPConfigFile(
            for: configuration,
            scratchDirectory: scratchDirectory,
            in: tempDirectory
        )
        scopedMCPConfigURL = generatedMCPConfigURL
        runtimeConfiguration.mcpConfigPath = generatedMCPConfigURL.path
    } else {
        scopedMCPConfigURL = nil
    }
    let outputURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-\(UUID().uuidString).txt")
    let stdoutURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-stdout-\(UUID().uuidString).log")
    let stderrURL = tempDirectory.appendingPathComponent("thebrowser-\(configuration.provider.rawValue)-stderr-\(UUID().uuidString).log")
    let systemPromptFileURL = try systemPromptFileIfNeeded(for: runtimeConfiguration, in: tempDirectory)

    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    defer {
        try? FileManager.default.removeItem(at: outputURL)
        if let scopedMCPConfigURL {
            try? FileManager.default.removeItem(at: scopedMCPConfigURL)
        }
        if let systemPromptFileURL {
            try? FileManager.default.removeItem(at: systemPromptFileURL)
        }
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: runtimeConfiguration.cliPath)
    process.standardOutput = stdout
    process.standardError = stderr
    let standardInputData = CLIArguments.standardInputData(for: runtimeConfiguration, prompt: prompt)
    let stdin = standardInputData == nil ? nil : Pipe()
    if let stdin {
        process.standardInput = stdin
    }
    process.currentDirectoryURL = URL(fileURLWithPath: runtimeConfiguration.workspacePath, isDirectory: true)
    process.arguments = CLIArguments.arguments(
        for: runtimeConfiguration,
        prompt: prompt,
        outputURL: outputURL,
        systemPromptFileURL: systemPromptFileURL
    )

    try process.run()
    if let standardInputData, let stdin {
        stdin.fileHandleForWriting.write(standardInputData)
        try? stdin.fileHandleForWriting.close()
    }
    process.waitUntilExit()

    try stdout.close()
    try stderr.close()

    let finalMessage = (try? String(contentsOf: outputURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

    guard process.terminationStatus == 0 else {
        let providerOutput: String
        if runtimeConfiguration.provider == .claude,
           let result = ClaudeJSONResponse.result(from: stdoutText) {
            providerOutput = [stderrText.trimmingCharacters(in: .whitespacesAndNewlines), result]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            providerOutput = [stderrText, stdoutText].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        throw AIProviderError.processFailed(provider: runtimeConfiguration.provider, status: process.terminationStatus, output: providerOutput)
    }

    if runtimeConfiguration.provider == .codex, let finalMessage, !finalMessage.isEmpty {
        return finalMessage
    }

    let fallback = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty {
        if runtimeConfiguration.provider == .claude, let result = ClaudeJSONResponse.result(from: fallback) {
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

private func scopedMCPConfigFile(
    for configuration: AIHarnessConfiguration,
    scratchDirectory: URL,
    in directory: URL
) throws -> URL {
    let url = directory.appendingPathComponent("thebrowser-mcp-\(configuration.provider.rawValue)-\(UUID().uuidString).json")
    let data = try MCPConfigBuilder.claudeConfigData(
        existingConfigPath: configuration.mcpConfigPath,
        scratchDirectory: scratchDirectory
    )
    try data.write(to: url, options: .atomic)
    return url
}

enum MCPFilesystemServer {
    static let name = "filesystem"
    static let command = "npx"
    static let packageName = "@modelcontextprotocol/server-filesystem"

    static func args(for scratchDirectory: URL) -> [String] {
        ["-y", packageName, scratchDirectory.path]
    }

    static func dictionary(for scratchDirectory: URL) -> [String: Any] {
        [
            "command": command,
            "args": args(for: scratchDirectory)
        ]
    }
}

enum MCPConfigBuilder {
    static func claudeConfigData(existingConfigPath: String, scratchDirectory: URL) throws -> Data {
        var root = try existingClaudeConfig(path: existingConfigPath)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[MCPFilesystemServer.name] = MCPFilesystemServer.dictionary(for: scratchDirectory)
        root["mcpServers"] = servers

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func existingClaudeConfig(path: String) throws -> [String: Any] {
        let trimmedPath = CLIArguments.trimmed(path)
        guard !trimmedPath.isEmpty else { return [:] }

        let url = URL(fileURLWithPath: trimmedPath)
        do {
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw AIProviderError.invalidMCPConfig(path: trimmedPath, reason: "top-level JSON must be an object")
            }
            return dictionary
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidMCPConfig(path: trimmedPath, reason: error.localizedDescription)
        }
    }
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

        appendCodexFilesystemMCPServer(root: configuration.scopedFilesystemRoot, to: &arguments)
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

    static func appendCodexFilesystemMCPServer(root: String?, to arguments: inout [String]) {
        let root = trimmed(root ?? "")
        guard !root.isEmpty else { return }

        let scratchDirectory = URL(fileURLWithPath: root, isDirectory: true)
        appendConfigOverride("mcp_servers.filesystem.command", stringValue: MCPFilesystemServer.command, to: &arguments)
        appendConfigOverride("mcp_servers.filesystem.args", arrayValue: MCPFilesystemServer.args(for: scratchDirectory), to: &arguments)
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

    static func appendConfigOverride(_ key: String, arrayValue: [String], to arguments: inout [String]) {
        arguments.append(contentsOf: ["-c", "\(key)=\(tomlArrayLiteral(arrayValue))"])
    }

    static func tomlStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func tomlArrayLiteral(_ values: [String]) -> String {
        "[\(values.map(tomlStringLiteral).joined(separator: ", "))]"
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

private extension UserDefaults {
    func persistedString(forKey key: String) -> String? {
        object(forKey: key) as? String
    }
}
