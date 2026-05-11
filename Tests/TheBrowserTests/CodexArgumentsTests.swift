import Foundation
import Testing
@testable import TheBrowser

@Suite("Codex CLI arguments")
struct CodexArgumentsTests {
    @Test("Baseline arguments use Codex exec with isolated config, no persisted session, workspace, output, and raw user prompt")
    func baselineArguments() {
        let config = TestSupport.makeConfiguration(
            provider: .codex,
            workspacePath: "/work",
            sandbox: "read-only"
        )

        let args = CLIArguments.codexArguments(
            for: config,
            prompt: "hi",
            outputURL: URL(fileURLWithPath: "/tmp/out.txt")
        )

        #expect(args.first == "exec")
        #expect(args.contains("--color"))
        #expect(args.contains("never"))
        #expect(args.contains("--skip-git-repo-check"))
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ignore-rules"))
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("-C"))
        #expect(args.contains("/work"))
        #expect(args.contains("-o"))
        #expect(args.contains("/tmp/out.txt"))
        #expect(args.last == "hi")
    }

    @Test("Baseline always includes isolation flags to stop user-level config and rules from leaking in")
    func isolationFlagsAlwaysPresent() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ignore-rules"))
        #expect(args.contains("--ephemeral"))
    }

    @Test("Sandbox value is forwarded verbatim")
    func sandboxIsForwarded() {
        let config = TestSupport.makeConfiguration(provider: .codex, sandbox: "workspace-write")

        let args = CLIArguments.codexArguments(
            for: config,
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        let sandboxIndex = args.firstIndex(of: "--sandbox")!
        #expect(args[sandboxIndex + 1] == "workspace-write")
    }

    @Test("Model flag appears only when model is non-empty")
    func modelFlagOmittedWhenEmpty() {
        let withoutModel = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, model: ""),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )
        let whitespaceModel = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, model: "   "),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        #expect(!withoutModel.contains("--model"))
        #expect(!whitespaceModel.contains("--model"))
    }

    @Test("Model flag is present and trimmed when non-empty")
    func modelFlagIncluded() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, model: "  gpt-5  "),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        let modelIndex = args.firstIndex(of: "--model")!
        #expect(args[modelIndex + 1] == "gpt-5")
    }

    @Test("System prompt is supplied through model_instructions_file, not injected into the user prompt")
    func systemPromptUsesModelInstructionsFile() {
        let systemPromptURL = URL(fileURLWithPath: "/tmp/thebrowser system \"prompt\".md")
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, systemPrompt: "Be terse."),
            prompt: "What time is it?",
            outputURL: TestSupport.outputURL,
            systemPromptFileURL: systemPromptURL
        )

        #expect(args.last == "What time is it?")
        #expect(!args.last!.contains("System instructions:"))
        #expect(!args.last!.contains("Be terse."))
        #expect(configOverrides(in: args).contains("model_instructions_file=\"/tmp/thebrowser system \\\"prompt\\\".md\""))
    }

    @Test("Codex harness prompt fragments are disabled")
    func harnessPromptFragmentsDisabled() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex),
            prompt: "p",
            outputURL: TestSupport.outputURL,
            systemPromptFileURL: URL(fileURLWithPath: "/tmp/system.md")
        )
        let overrides = configOverrides(in: args)

        #expect(overrides.contains("include_permissions_instructions=false"))
        #expect(overrides.contains("include_apps_instructions=false"))
        #expect(overrides.contains("include_environment_context=false"))
        #expect(overrides.contains("skills.include_instructions=false"))
        #expect(overrides.contains("include_apply_patch_tool=false"))
    }

    @Test("Codex harness tools are disabled by feature flag")
    func harnessToolsDisabled() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        let disabledFeatures = disabledFeatureFlags(in: args)
        let expected = [
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

        for feature in expected {
            #expect(disabledFeatures.contains(feature), "Codex should disable \(feature)")
        }
    }

    @Test("Extra arguments are split by newlines and blanks dropped")
    func extraArgumentsSplitByNewlines() {
        let extras = "--foo\n  \n--bar\n--baz value"
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, extraArguments: extras),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        #expect(args.contains("--foo"))
        #expect(args.contains("--bar"))
        #expect(args.contains("--baz value"))
        #expect(!args.contains(""))
    }

    @Test("Reasoning effort is passed as a Codex config override")
    func reasoningEffortConfigOverride() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, reasoningEffort: " medium "),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        #expect(configOverrides(in: args).contains("model_reasoning_effort=\"medium\""))
    }

    @Test("Codex never emits Claude-only flags")
    func codexNeverEmitsClaudeFlags() {
        let config = TestSupport.makeConfiguration(
            provider: .codex,
            systemPrompt: "Be terse.",
            tools: "Read,Edit",
            allowedTools: "Bash",
            disallowedTools: "Write",
            mcpConfigPath: "/tmp/mcp.json"
        )

        let args = CLIArguments.codexArguments(
            for: config,
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        let claudeOnly = [
            "--print",
            "--input-format",
            "--output-format",
            "--no-session-persistence",
            "--bare",
            "--append-system-prompt",
            "--system-prompt",
            "--tools",
            "--allowedTools",
            "--disallowedTools",
            "--mcp-config"
        ]
        for flag in claudeOnly {
            #expect(!args.contains(flag), "Codex should not emit \(flag)")
        }
    }

    @Test("Dispatch via arguments(for:) routes to codex builder")
    func dispatchSelectsCodexBuilder() {
        let args = CLIArguments.arguments(
            for: TestSupport.makeConfiguration(provider: .codex),
            prompt: "p",
            outputURL: TestSupport.outputURL,
            systemPromptFileURL: URL(fileURLWithPath: "/tmp/system.md")
        )

        #expect(args.first == "exec")
        #expect(configOverrides(in: args).contains("model_instructions_file=\"/tmp/system.md\""))
    }

    @Test("TOML string literals escape quotes and backslashes")
    func tomlStringEscapesPath() {
        #expect(CLIArguments.tomlStringLiteral(#"/tmp/a "quoted" \ path.md"#) == #""/tmp/a \"quoted\" \\ path.md""#)
    }

    private func configOverrides(in args: [String]) -> [String] {
        values(after: "-c", in: args)
    }

    private func disabledFeatureFlags(in args: [String]) -> [String] {
        values(after: "--disable", in: args)
    }

    private func values(after flag: String, in args: [String]) -> [String] {
        args.indices.compactMap { index in
            guard args[index] == flag, args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
    }
}
