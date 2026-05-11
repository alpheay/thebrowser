import Foundation
import Testing
@testable import TheBrowser

@Suite("Claude CLI arguments")
struct ClaudeArgumentsTests {
    @Test("Baseline arguments replace the prompt, keep normal auth, disable slash commands, disable default tools, and leave user input for stdin")
    func baselineArguments() {
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude),
            prompt: "hi"
        )

        #expect(args == [
            "--print",
            "--input-format", "text",
            "--output-format", "json",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-chrome",
            "--system-prompt", CLIArguments.effectiveSystemPrompt(for: TestSupport.makeConfiguration(provider: .claude)),
            "--tools", ""
        ])
        #expect(!args.contains("hi"))
    }

    @Test("Model flag appears only when model is non-empty")
    func modelFlagOmittedWhenEmpty() {
        let withoutModel = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, model: ""),
            prompt: "p"
        )
        let whitespaceModel = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, model: " \n "),
            prompt: "p"
        )

        #expect(!withoutModel.contains("--model"))
        #expect(!whitespaceModel.contains("--model"))
    }

    @Test("Model flag is present and trimmed when non-empty")
    func modelFlagIncluded() {
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, model: "  claude-opus-4-7  "),
            prompt: "p"
        )

        let modelIndex = args.firstIndex(of: "--model")!
        #expect(args[modelIndex + 1] == "claude-opus-4-7")
    }

    @Test("System prompt uses --system-prompt flag (replaces, never appends, the default)")
    func systemPromptUsesReplaceFlag() {
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, systemPrompt: "  Be terse.  "),
            prompt: "p"
        )

        #expect(!args.contains("--append-system-prompt"))
        let flagIndex = args.firstIndex(of: "--system-prompt")!
        let value = args[flagIndex + 1]
        #expect(value == "Be terse.")
        #expect(!value.contains("Claude"))
        #expect(!value.contains("Codex"))
    }

    @Test("--system-prompt is always present, even when the configured prompt is blank, so the CLI default is replaced")
    func systemPromptAlwaysPresent() {
        let empty = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, systemPrompt: ""),
            prompt: "p"
        )
        let whitespace = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, systemPrompt: "   \n\t  "),
            prompt: "p"
        )

        #expect(empty.contains("--system-prompt"))
        #expect(whitespace.contains("--system-prompt"))

        let emptyFlagIndex = empty.firstIndex(of: "--system-prompt")!
        #expect(empty[emptyFlagIndex + 1].isEmpty)
    }

    @Test("Tool flags are included only when their value is non-empty after trim",
          arguments: [
            ("--tools", "Read,Edit"),
            ("--allowedTools", "Bash"),
            ("--disallowedTools", "Write"),
            ("--mcp-config", "/tmp/mcp.json")
          ])
    func toolFlagPresentWhenValueProvided(flag: String, value: String) {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            tools: flag == "--tools" ? value : "",
            allowedTools: flag == "--allowedTools" ? value : "",
            disallowedTools: flag == "--disallowedTools" ? value : "",
            mcpConfigPath: flag == "--mcp-config" ? value : ""
        )

        let args = CLIArguments.claudeArguments(for: config, prompt: "p")

        let flagIndex = args.firstIndex(of: flag)!
        #expect(args[flagIndex + 1] == value)
    }

    @Test("Default tools are explicitly disabled while optional tool flags are omitted when blank")
    func toolFlagsOmittedWhenBlank() {
        let allBlank = TestSupport.makeConfiguration(
            provider: .claude,
            tools: "",
            allowedTools: "   ",
            disallowedTools: "\n\t",
            mcpConfigPath: "  "
        )

        let args = CLIArguments.claudeArguments(for: allBlank, prompt: "p")

        let toolsIndex = args.firstIndex(of: "--tools")!
        #expect(args[toolsIndex + 1] == "")
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--disallowedTools"))
        #expect(!args.contains("--mcp-config"))
    }

    @Test("Replacement flags are present without bare mode so Claude can use normal login auth")
    func replacementFlagsPresentWithoutBareMode() {
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude),
            prompt: "p"
        )

        #expect(!args.contains("--bare"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-chrome"))
    }

    @Test("User prompt is supplied through stdin so variadic tool parsing cannot consume it")
    func userPromptUsesStandardInput() throws {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            model: "claude-sonnet-4-6",
            systemPrompt: "rules",
            tools: "Read",
            allowedTools: "Bash",
            disallowedTools: "Write",
            mcpConfigPath: "/tmp/mcp.json",
            extraArguments: "--verbose"
        )

        let args = CLIArguments.claudeArguments(for: config, prompt: "FINAL_PROMPT")
        let stdin = try #require(CLIArguments.standardInputData(for: config, prompt: "FINAL_PROMPT"))

        #expect(!args.contains("FINAL_PROMPT"))
        #expect(String(data: stdin, encoding: .utf8) == "FINAL_PROMPT")
        #expect(args.firstIndex(of: "--tools") != nil)
    }

    @Test("Extra arguments are split by newlines and blanks dropped, order preserved")
    func extraArgumentsSplit() {
        let extras = "--verbose\n  \n--foo bar\n\n--baz"
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, extraArguments: extras),
            prompt: "p"
        )

        let verbose = args.firstIndex(of: "--verbose")!
        let foo = args.firstIndex(of: "--foo bar")!
        let baz = args.firstIndex(of: "--baz")!
        #expect(verbose < foo)
        #expect(foo < baz)
        #expect(CLIArguments.extraArguments(from: extras) == ["--verbose", "--foo bar", "--baz"])
    }

    @Test("Reasoning effort is passed through Claude effort flag")
    func reasoningEffortFlag() {
        let args = CLIArguments.claudeArguments(
            for: TestSupport.makeConfiguration(provider: .claude, reasoningEffort: " medium "),
            prompt: "p"
        )

        let effortIndex = args.firstIndex(of: "--effort")!
        #expect(args[effortIndex + 1] == "medium")
    }

    @Test("Claude never emits Codex-only flags")
    func claudeNeverEmitsCodexFlags() {
        let config = TestSupport.makeConfiguration(
            provider: .claude,
            workspacePath: "/work",
            sandbox: "workspace-write"
        )

        let args = CLIArguments.claudeArguments(for: config, prompt: "p")

        let codexOnly = [
            "exec", "--sandbox", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules",
            "--color", "-C", "-o"
        ]
        for flag in codexOnly {
            #expect(!args.contains(flag), "Claude should not emit \(flag)")
        }
    }

    @Test("Dispatch via arguments(for:) routes to claude builder")
    func dispatchSelectsClaudeBuilder() {
        let args = CLIArguments.arguments(
            for: TestSupport.makeConfiguration(provider: .claude),
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        #expect(args.first == "--print")
    }

    @Test("Codex still receives the prompt as an argv argument, not stdin")
    func codexDoesNotUseStandardInput() {
        let config = TestSupport.makeConfiguration(provider: .codex)

        #expect(CLIArguments.standardInputData(for: config, prompt: "p") == nil)
    }
}
