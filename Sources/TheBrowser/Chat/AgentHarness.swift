import Foundation

/// One event from a CLI subprocess as it produces output. The chat loop
/// consumes these so that long-form prose appears character-by-character
/// instead of dumping in a single block once the model finishes.
///
/// Only Claude currently emits true streaming events (`stream-json`
/// output). For Codex we wrap the existing single-shot path into a
/// stream that yields one `.result` at the end, which keeps the chat
/// loop provider-agnostic.
enum HarnessEvent: Sendable {
    /// A text chunk from the assistant. Append to the live message body.
    case textDelta(String)
    /// The CLI finished. `text` is the final, authoritative response —
    /// equal to the concatenation of all text deltas, but the consumer
    /// should trust this over the accumulated stream in case the model
    /// produced anything we couldn't parse from the deltas.
    case result(text: String)
}

/// Maximum number of tool iterations the harness will run for a single
/// user turn. opencode-style "unbounded" looping is the goal, but we keep
/// a generous ceiling so a runaway model can't burn the user's quota
/// indefinitely. 25 leaves room for a multi-step workflow (search → open
/// → fetch → mail_search → mail_read → mail_draft → create_artifact …)
/// while still bounding worst-case spend.
let maxAgentIterations = 25

/// The reason a turn ended — useful both for telemetry-style UI footers
/// and for deciding what message to leave in place once the live in-flight
/// bubble is finalized.
enum AgentTurnOutcome: Equatable {
    /// The model produced final prose. No more tool calls pending.
    case completed
    /// The user pressed Stop while the turn was in flight. Whatever the
    /// model managed to say so far is preserved; in-flight tool entries
    /// roll back to `.failed`.
    case cancelled
    /// We hit the iteration ceiling. The chain is preserved; a synthetic
    /// "stopped to avoid looping" note is appended to the body so the user
    /// understands why the turn ended.
    case capped
    /// Surface-level harness failure (CLI not found, process crashed, no
    /// usable response). The error is rendered as a system pill below the
    /// partial assistant bubble.
    case failed(String)
}

/// Cancellation handle the ChatViewModel hands to the harness. Tapping
/// "Stop" on the composer flips `isCancelled` and terminates any running
/// CLI subprocess so the iteration loop exits at the next checkpoint.
///
/// Two separate concerns are bundled here on purpose: a cooperative flag
/// the Swift Task can poll between iterations, and a Process reference
/// (set/cleared by `runProvider`) so the CLI binary itself can be killed
/// mid-call rather than waiting for the model to finish typing.
final class AgentRunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _process: Process?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    func attach(process: Process) {
        lock.lock(); defer { lock.unlock() }
        if _isCancelled {
            // Cancellation arrived between iteration boundaries — kill
            // the subprocess immediately so we don't wait for it to
            // produce output we'd just throw away.
            process.terminate()
            return
        }
        _process = process
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        _process = nil
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _isCancelled = true
        _process?.terminate()
    }
}

/// Compact description of what a tool is doing, used in the streaming
/// status row underneath the live assistant bubble. e.g. for
/// `{"tool":"mail_search","mailbox":"inbox"}` we surface
/// "Reading inbox…" rather than the raw JSON.
enum AgentStatusLabel {
    static func forActiveTool(_ call: NativeBrowserToolCall) -> String {
        switch call.name {
        case .open:
            return "Opening \(displayHost(call.url) ?? "tab")…"
        case .search:
            return "Searching the web…"
        case .fetch:
            return "Fetching \(displayHost(call.url) ?? "page")…"
        case .readTabs:
            return "Reading open tabs…"
        case .readHighlights:
            return "Reading highlights…"
        case .readSmartRead:
            return "Reading Smart Read…"
        case .mailSearch:
            return "Searching mail…"
        case .mailReadThread:
            return "Reading mail thread…"
        case .mailReadCurrent:
            return "Reading this email…"
        case .mailShow:
            return "Opening mail…"
        case .mailDraft:
            return "Drafting reply…"
        case .mailCompose:
            return "Writing in composer…"
        case .mailSend:
            return "Sending mail…"
        case .mailModify:
            return "Organizing mail…"
        case .mailTriage:
            return "Triaging inbox…"
        case .mailMemory:
            return "Updating memory…"
        case .mailRemind:
            return "Setting reminder…"
        case .createArtifact:
            return "Saving artifact…"
        case .webControl:
            return "Controlling page…"
        }
    }

    static let thinking = "Thinking…"

    private static func displayHost(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), let host = url.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        if let url = URL(string: "https://\(raw)"), let host = url.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        return nil
    }
}
