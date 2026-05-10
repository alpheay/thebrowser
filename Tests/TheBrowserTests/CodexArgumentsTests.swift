import Foundation
import Testing
@testable import TheBrowser

@Suite("Codex CLI arguments")
struct CodexArgumentsTests {
    @Test("Baseline arguments include exec, color, sandbox, workspace, output, and prompt")
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

        #expect(args == [
            "exec",
            "--color", "never",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-C", "/work",
            "-o", "/tmp/out.txt",
            "hi"
        ])
    }

    @Test("Sandbox value is forwarded verbatim")
    func sandboxIsForwarded() {
        let config = TestSupport.makeConfiguration(provider: .codex, sandbox: "workspace-write")

        let args = CLIArguments.codexArguments(
            for: config,
            prompt: "p",
            outputURL: TestSupport.outputURL
        )

        let sandboxIndex = try? #require(args.firstIndex(of: "--sandbox"))
        #expect(args[sandboxIndex! + 1] == "workspace-write")
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

        let modelIndex = try? #require(args.firstIndex(of: "--model"))
        #expect(args[modelIndex! + 1] == "gpt-5")
    }

    @Test("System prompt is prepended into the final positional argument, not as a flag")
    func systemPromptPrependedIntoPrompt() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, systemPrompt: "Be terse."),
            prompt: "What time is it?",
            outputURL: TestSupport.outputURL
        )

        #expect(!args.contains("--append-system-prompt"))
        let last = try? #require(args.last)
        #expect(last!.contains("System instructions:"))
        #expect(last!.contains("Be terse."))
        #expect(last!.contains("What time is it?"))
    }

    @Test("Empty system prompt leaves the user prompt untouched")
    func emptySystemPromptLeavesPromptAlone() {
        let args = CLIArguments.codexArguments(
            for: TestSupport.makeConfiguration(provider: .codex, systemPrompt: "   \n\n"),
            prompt: "raw user prompt",
            outputURL: TestSupport.outputURL
        )

        #expect(args.last == "raw user prompt")
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
            "--output-format",
            "--no-session-persistence",
            "--append-system-prompt",
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
            outputURL: TestSupport.outputURL
        )

        #expect(args.first == "exec")
    }

    @Test("codexPrompt prepends system instructions block when non-empty")
    func codexPromptCombinesSystemAndUser() {
        let combined = CLIArguments.codexPrompt(systemPrompt: "rules", prompt: "ask")
        #expect(combined == """
        System instructions:
        rules

        ask
        """)
    }

    @Test("codexPrompt returns the user prompt unchanged when system prompt is empty")
    func codexPromptUntouchedWhenSystemEmpty() {
        #expect(CLIArguments.codexPrompt(systemPrompt: "", prompt: "ask") == "ask")
        #expect(CLIArguments.codexPrompt(systemPrompt: "  \n", prompt: "ask") == "ask")
    }
}
