import Foundation

enum CodexCLIError: LocalizedError {
    case missingExecutable(String)
    case processFailed(Int32, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            return "Codex CLI was not found at \(path). Open Settings and choose the CLI path."
        case .processFailed(let status, let output):
            return "Codex exited with status \(status).\n\(output)"
        case .emptyResponse:
            return "Codex finished without returning a message."
        }
    }
}

struct CodexRunConfiguration: Sendable {
    var cliPath: String
    var workspacePath: String
    var model: String
    var sandbox: String

    static func current() -> CodexRunConfiguration {
        let defaults = UserDefaults.standard
        let cliPath = defaults.string(forKey: PreferenceKey.codexCLIPath) ?? AppDefaults.defaultCodexCLIPath()
        let workspacePath = defaults.string(forKey: PreferenceKey.codexWorkspacePath)
            ?? AppDefaults.defaultCodexWorkspacePath()
        let model = defaults.string(forKey: PreferenceKey.codexModel) ?? ""
        let sandbox = defaults.string(forKey: PreferenceKey.codexSandbox) ?? "read-only"

        return CodexRunConfiguration(
            cliPath: cliPath,
            workspacePath: workspacePath,
            model: model,
            sandbox: sandbox
        )
    }
}

struct CodexCLIClient {
    func ask(_ message: String, context: BrowserPageContext) async throws -> String {
        let configuration = CodexRunConfiguration.current()
        let prompt = Self.prompt(for: message, context: context)

        return try await Task.detached(priority: .userInitiated) {
            try runCodex(configuration: configuration, prompt: prompt)
        }.value
    }

    private static func prompt(for message: String, context: BrowserPageContext) -> String {
        let pageURL = context.url.isEmpty ? "Home page" : context.url

        return """
        You are The Browser's native AI assistant, running through Codex CLI.
        Stay concise, useful, and practical. If the user asks for browser actions that this early app cannot do yet, say what you can help with now.

        Current tab:
        Title: \(context.title)
        URL: \(pageURL)

        User request:
        \(message)
        """
    }
}

private func runCodex(configuration: CodexRunConfiguration, prompt: String) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: configuration.cliPath) else {
        throw CodexCLIError.missingExecutable(configuration.cliPath)
    }

    let tempDirectory = FileManager.default.temporaryDirectory
    let outputURL = tempDirectory.appendingPathComponent("thebrowser-codex-\(UUID().uuidString).txt")
    let stdoutURL = tempDirectory.appendingPathComponent("thebrowser-codex-stdout-\(UUID().uuidString).log")
    let stderrURL = tempDirectory.appendingPathComponent("thebrowser-codex-stderr-\(UUID().uuidString).log")

    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    defer {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.cliPath)
    process.standardOutput = stdout
    process.standardError = stderr

    var arguments = [
        "exec",
        "--color", "never",
        "--ask-for-approval", "never",
        "--skip-git-repo-check",
        "--sandbox", configuration.sandbox
    ]

    if !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        arguments.append(contentsOf: ["--model", configuration.model])
    }

    arguments.append(contentsOf: [
        "-C", configuration.workspacePath,
        "-o", outputURL.path,
        prompt
    ])

    process.arguments = arguments

    try process.run()
    process.waitUntilExit()

    try stdout.close()
    try stderr.close()

    let finalMessage = (try? String(contentsOf: outputURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

    guard process.terminationStatus == 0 else {
        let combined = [stderrText, stdoutText].filter { !$0.isEmpty }.joined(separator: "\n")
        throw CodexCLIError.processFailed(process.terminationStatus, combined)
    }

    if let finalMessage, !finalMessage.isEmpty {
        return finalMessage
    }

    let fallback = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty {
        return fallback
    }

    throw CodexCLIError.emptyResponse
}
