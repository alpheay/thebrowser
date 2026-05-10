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

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let provider, let path):
            return "\(provider.assistantDescription) was not found at \(path). Open Settings and choose the CLI path."
        case .processFailed(let provider, let status, let output):
            return "\(provider.displayName) exited with status \(status).\n\(output)"
        case .emptyResponse:
            return "The selected AI provider finished without returning a message."
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
            extraArguments: defaults.string(forKey: PreferenceKey.aiExtraArguments) ?? ""
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
        history: [ChatMessage] = []
    ) async throws -> String {
        let configuration = AIHarnessConfiguration.current()
        let prompt = Self.prompt(for: message, context: context, history: history, configuration: configuration)
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
        modelOverride: String? = nil
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

        let resolvedConfig = configuration
        return try await Task.detached(priority: .userInitiated) {
            try runProvider(configuration: resolvedConfig, prompt: prompt)
        }.value
    }

    static func prompt(
        for message: String,
        context: BrowserPageContext,
        history: [ChatMessage] = [],
        configuration: AIHarnessConfiguration? = nil
    ) -> String {
        let pageURL = context.url.isEmpty ? "Home page" : context.url

        // Conversation history excludes the user message just appended (it
        // becomes the explicit "User request" below) and any system rows
        // (those are local error notices, not part of the dialogue).
        let priorTurns = history.dropLast().filter { $0.role != .system }

        var transcript = ""
        if !priorTurns.isEmpty {
            transcript = "Conversation so far:\n"
            for msg in priorTurns {
                let label = msg.role == .user ? "User" : "Assistant"
                transcript += "\(label): \(msg.text)\n"
            }
            transcript += "\n"
        }

        return """
        \(NativeBrowserToolPrompt.instructions)

        \(configuration?.promptIdentity ?? "")

        Current tab:
        Title: \(context.title)
        URL: \(pageURL)

        \(transcript)User request:
        \(message)
        """
    }
}

private func runProvider(configuration: AIHarnessConfiguration, prompt: String) throws -> String {
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

private extension UserDefaults {
    func persistedString(forKey key: String) -> String? {
        object(forKey: key) as? String
    }
}
