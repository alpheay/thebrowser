import Foundation
@testable import TheBrowser

enum TestSupport {
    static func makeConfiguration(
        provider: AIProviderKind,
        cliPath: String = "/tmp/fake-cli",
        workspacePath: String = "/tmp/workspace",
        model: String = "",
        sandbox: String = "read-only",
        systemPrompt: String = "",
        tools: String = "",
        allowedTools: String = "",
        disallowedTools: String = "",
        mcpConfigPath: String = "",
        extraArguments: String = "",
        reasoningEffort: String = ""
    ) -> AIHarnessConfiguration {
        AIHarnessConfiguration(
            provider: provider,
            cliPath: cliPath,
            workspacePath: workspacePath,
            model: model,
            sandbox: sandbox,
            systemPrompt: systemPrompt,
            tools: tools,
            allowedTools: allowedTools,
            disallowedTools: disallowedTools,
            mcpConfigPath: mcpConfigPath,
            extraArguments: extraArguments,
            reasoningEffort: reasoningEffort
        )
    }

    static let outputURL = URL(fileURLWithPath: "/tmp/output.txt")
}
