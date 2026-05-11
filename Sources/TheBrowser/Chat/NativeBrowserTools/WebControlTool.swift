import Foundation
@preconcurrency import WebKit

struct WebControlStatus: Equatable {
    var task: String
    var detail: String
    var step: Int
}

struct WebControlAgentOutcome: Equatable, Sendable {
    var succeeded: Bool
    var summary: String
    var stepCount: Int
}

extension NativeBrowserToolExecutor {
    /// Dispatcher entry point - call via execute(_:).
    func webControl(_ call: NativeBrowserToolCall) async -> NativeBrowserToolResult {
        let task = call.rawInput
        let outcome = await runWebControl(task)
        let content = """
        Task: \(task)
        Steps: \(outcome.stepCount)
        Result:
        \(outcome.summary)
        """

        return NativeBrowserToolResult(
            call: call,
            succeeded: outcome.succeeded,
            content: content
        )
    }
}

struct WebControlAgentCommand: Equatable, Sendable {
    enum Action: String, Sendable {
        case click
        case type
        case pressKey = "press_key"
        case scroll
        case wait
        case navigate
        case readPage = "read_page"
        case finish
    }

    var action: Action
    var id: String? = nil
    var selector: String? = nil
    var text: String? = nil
    var key: String? = nil
    var url: String? = nil
    var direction: String? = nil
    var amount: Int? = nil
    var seconds: Double? = nil
    var clear: Bool = false
    var success: Bool? = nil
    var answer: String? = nil

    static func parse(from text: String) -> WebControlAgentCommand? {
        for candidate in jsonObjectCandidates(in: text) {
            if let command = parse(json: candidate) {
                return command
            }
        }
        return nil
    }

    var compactDescription: String {
        switch action {
        case .click:
            return "click \(idOrSelector)"
        case .type:
            return "type into \(idOrSelector)"
        case .pressKey:
            return "press \(key ?? "")"
        case .scroll:
            return "scroll \(direction ?? "") \(amount.map(String.init) ?? "")"
        case .wait:
            return "wait \(seconds.map { String(format: "%.1f", $0) } ?? "")s"
        case .navigate:
            return "navigate \(url ?? "")"
        case .readPage:
            return "read page"
        case .finish:
            return "finish"
        }
    }

    var statusDetail: String {
        switch action {
        case .click:
            return "Clicking page element"
        case .type:
            return "Typing into page"
        case .pressKey:
            return "Pressing \(key ?? "key")"
        case .scroll:
            return "Scrolling page"
        case .wait:
            return "Waiting for page update"
        case .navigate:
            return "Navigating page"
        case .readPage:
            return "Reading page"
        case .finish:
            return "Finishing task"
        }
    }

    private var idOrSelector: String {
        if let id, !id.isEmpty { return "#\(id)" }
        if let selector, !selector.isEmpty { return selector }
        return "(current focus)"
    }

    private static func parse(json: String) -> WebControlAgentCommand? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let arguments = dictionary["arguments"] as? [String: Any] ?? [:]
        let rawAction = stringValue(named: "action", in: dictionary, arguments: arguments)
            ?? stringValue(named: "tool", in: dictionary, arguments: arguments)
            ?? stringValue(named: "name", in: dictionary, arguments: arguments)

        guard
            let rawAction,
            let action = Action(rawValue: rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return nil
        }

        let command = WebControlAgentCommand(
            action: action,
            id: stringValue(named: "id", in: dictionary, arguments: arguments)
                ?? stringValue(named: "element_id", in: dictionary, arguments: arguments),
            selector: stringValue(named: "selector", in: dictionary, arguments: arguments),
            text: stringValue(named: "text", in: dictionary, arguments: arguments)
                ?? stringValue(named: "value", in: dictionary, arguments: arguments),
            key: stringValue(named: "key", in: dictionary, arguments: arguments),
            url: stringValue(named: "url", in: dictionary, arguments: arguments),
            direction: stringValue(named: "direction", in: dictionary, arguments: arguments),
            amount: intValue(named: "amount", in: dictionary, arguments: arguments)
                ?? intValue(named: "pixels", in: dictionary, arguments: arguments),
            seconds: doubleValue(named: "seconds", in: dictionary, arguments: arguments),
            clear: boolValue(named: "clear", in: dictionary, arguments: arguments) ?? false,
            success: boolValue(named: "success", in: dictionary, arguments: arguments),
            answer: stringValue(named: "answer", in: dictionary, arguments: arguments)
                ?? stringValue(named: "summary", in: dictionary, arguments: arguments)
        )

        switch action {
        case .click:
            return command.id != nil || command.selector != nil ? command : nil
        case .type:
            return command.text != nil ? command : nil
        case .pressKey:
            return command.key != nil ? command : nil
        case .navigate:
            return command.url != nil ? command : nil
        case .finish:
            return command
        case .scroll, .wait, .readPage:
            return command
        }
    }

    private static func stringValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> String? {
        let raw = (dictionary[key] as? String) ?? (arguments[key] as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func intValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> Int? {
        let raw = dictionary[key] ?? arguments[key]
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> Double? {
        let raw = dictionary[key] ?? arguments[key]
        if let double = raw as? Double { return double }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func boolValue(named key: String, in dictionary: [String: Any], arguments: [String: Any]) -> Bool? {
        let raw = dictionary[key] ?? arguments[key]
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            candidates.append(trimmed)
        }

        if let leading = leadingJSONObject(in: trimmed) {
            candidates.append(leading)
        }

        let fencePattern = #"```(?:web_control|json)?\s*(\{[\s\S]*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: trimmed) else { continue }
                candidates.append(String(trimmed[range]))
            }
        }

        if let trailing = trailingJSONObject(in: trimmed) {
            candidates.append(trailing)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func leadingJSONObject(in text: String) -> String? {
        guard text.hasPrefix("{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(after: index)
                    let candidate = String(text[text.startIndex..<endIndex])
                    let remainder = text[endIndex..<text.endIndex]
                    return remainderIsParagraphBreakOrEmpty(remainder) ? candidate : nil
                }
                if depth < 0 { return nil }
            }
        }
        return nil
    }

    private static func trailingJSONObject(in text: String) -> String? {
        guard text.hasSuffix("}") else { return nil }

        var depth = 0
        var startIndex: String.Index? = nil
        var inString = false
        var escaped = false
        var lastCandidate: Range<String.Index>? = nil

        for index in text.indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    lastCandidate = start..<text.index(after: index)
                    startIndex = nil
                } else if depth < 0 {
                    return nil
                }
            }
        }

        guard let range = lastCandidate, range.upperBound == text.endIndex else {
            return nil
        }
        return String(text[range])
    }

    private static func remainderIsParagraphBreakOrEmpty(_ remainder: Substring) -> Bool {
        for character in remainder {
            if character.isNewline { return true }
            if !character.isWhitespace { return false }
        }
        return true
    }
}

@MainActor
final class WebControlAgentRunner {
    private let client: AIProviderClient
    private let maxSteps: Int

    init(client: AIProviderClient = AIProviderClient(), maxSteps: Int = 18) {
        self.client = client
        self.maxSteps = maxSteps
    }

    func run(
        task: String,
        tab: BrowserTab,
        sessionDirectory: URL,
        onStatus: @escaping @MainActor (WebControlStatus?) -> Void
    ) async -> WebControlAgentOutcome {
        let harness = WebControlHarness(tab: tab)
        var transcript: [String] = []
        let initialSnapshot = await harness.snapshot()
        transcript.append("Initial page snapshot:\n\(initialSnapshot)")

        for step in 1...maxSteps {
            onStatus(WebControlStatus(task: task, detail: "Planning next action", step: step))

            let prompt = WebControlAgentPrompt.stepPrompt(
                task: task,
                step: step,
                maxSteps: maxSteps,
                transcript: transcript
            )

            let response: String
            do {
                response = try await client.ask(
                    prompt: prompt,
                    sessionDirectory: sessionDirectory,
                    systemPromptOverride: WebControlAgentPrompt.systemPrompt,
                    reasoningEffortOverride: "medium"
                )
            } catch {
                return WebControlAgentOutcome(
                    succeeded: false,
                    summary: "The web control agent could not start: \(error.localizedDescription)",
                    stepCount: step - 1
                )
            }

            guard let command = WebControlAgentCommand.parse(from: response) else {
                return WebControlAgentOutcome(
                    succeeded: false,
                    summary: "The web control agent returned an invalid action instead of JSON: \(String(response.prefix(500)))",
                    stepCount: step - 1
                )
            }

            if command.action == .finish {
                return WebControlAgentOutcome(
                    succeeded: command.success ?? true,
                    summary: command.answer ?? "Finished.",
                    stepCount: step - 1
                )
            }

            onStatus(WebControlStatus(task: task, detail: command.statusDetail, step: step))
            let observation = await harness.perform(command)
            transcript.append("""
            Step \(step): \(command.compactDescription)
            \(observation)
            """)
            transcript = Array(transcript.suffix(5))
        }

        let snapshot = await harness.snapshot()
        return WebControlAgentOutcome(
            succeeded: false,
            summary: "Stopped after \(maxSteps) web-control steps to avoid looping. Latest page state:\n\(snapshot)",
            stepCount: maxSteps
        )
    }
}

private enum WebControlAgentPrompt {
    static let systemPrompt = """
    You are The Browser's web control agent. You are separate from the main chat assistant and operate only the user's visible browser tab through a harness.

    Use medium-depth reasoning internally, but respond with exactly one JSON object and no prose. Never use markdown fences unless you are forced by the model runtime. You do not have shell tools or network tools. Your only interface is the action JSON schema below and the page snapshots returned by the harness.

    Actions:
    {"action":"click","id":"element-id-from-snapshot"}
    {"action":"click","selector":"CSS selector fallback"}
    {"action":"type","id":"element-id-from-snapshot","text":"hello","clear":true}
    {"action":"press_key","key":"Enter"}
    {"action":"scroll","direction":"down","amount":700}
    {"action":"wait","seconds":1}
    {"action":"navigate","url":"https://example.com"}
    {"action":"read_page"}
    {"action":"finish","success":true,"answer":"Brief result for the user."}

    Prefer element ids from the snapshot over CSS selectors. Use type for normal text fields and press_key for global keyboard-driven apps and games. For Wordle-style games, inspect the board/status and on-screen keyboard in the snapshot, press letter keys and Enter, wait for feedback, then continue from the new board state. Keep going until the user's task is complete or clearly blocked.

    Do not perform destructive, purchase, account, or credential actions unless the user explicitly asked for that exact action in the task. If a site asks for login, payment, personal information, two-factor codes, or sensitive consent, finish with success=false and explain what is needed.
    """

    static func stepPrompt(
        task: String,
        step: Int,
        maxSteps: Int,
        transcript: [String]
    ) -> String {
        """
        User task:
        \(task)

        Step \(step) of at most \(maxSteps).

        Recent harness transcript:
        \(transcript.joined(separator: "\n\n---\n\n"))

        Reply with exactly one action JSON object. If the task is complete or blocked, use finish.
        """
    }
}

@MainActor
private final class WebControlHarness {
    private let tab: BrowserTab

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func perform(_ command: WebControlAgentCommand) async -> String {
        switch command.action {
        case .click:
            return await click(command)
        case .type:
            return await type(command)
        case .pressKey:
            return await pressKey(command)
        case .scroll:
            return await scroll(command)
        case .wait:
            return await wait(command)
        case .navigate:
            return await navigate(command)
        case .readPage:
            return "Read page.\n\(await snapshot())"
        case .finish:
            return "Finished."
        }
    }

    func snapshot(maxTextCharacters: Int = 6_000, maxElements: Int = 120, maxSignals: Int = 120) async -> String {
        if tab.isHome {
            return """
            Browser state:
            The current tab is the browser home screen. The harness can navigate to a URL if the task names a site, but there is no web page DOM to click yet.
            """
        }

        if let searchPage = tab.searchPage {
            return """
            Browser state:
            The current tab is the browser's native search results page for "\(searchPage.query)". This is not a WKWebView DOM, so the harness cannot click those native results. It can navigate directly to a URL or finish with what it needs.
            """
        }

        let script = Self.snapshotScript(maxTextCharacters: maxTextCharacters, maxElements: maxElements, maxSignals: maxSignals)
        do {
            let raw = try await tab.webView.evaluateJavaScript(script)
            if let string = raw as? String, !string.isEmpty {
                return string
            }
            return "Snapshot failed: page returned no state."
        } catch {
            return "Snapshot failed: \(error.localizedDescription)"
        }
    }

    private func click(_ command: WebControlAgentCommand) async -> String {
        let payload: [String: Any] = [
            "id": command.id ?? "",
            "selector": command.selector ?? ""
        ]

        let result = await evaluateAction(scriptName: "click", payload: payload, body: Self.clickScript)
        await settleBriefly()
        return "\(result)\n\(await snapshot())"
    }

    private func type(_ command: WebControlAgentCommand) async -> String {
        let payload: [String: Any] = [
            "id": command.id ?? "",
            "selector": command.selector ?? "",
            "text": command.text ?? "",
            "clear": command.clear
        ]

        let result = await evaluateAction(scriptName: "type", payload: payload, body: Self.typeScript)
        await settleBriefly()
        return "\(result)\n\(await snapshot())"
    }

    private func pressKey(_ command: WebControlAgentCommand) async -> String {
        let payload: [String: Any] = [
            "key": command.key ?? ""
        ]

        let result = await evaluateAction(scriptName: "press_key", payload: payload, body: Self.pressKeyScript)
        await settleBriefly()
        return "\(result)\n\(await snapshot())"
    }

    private func scroll(_ command: WebControlAgentCommand) async -> String {
        let direction = command.direction?.lowercased() ?? "down"
        let amount = command.amount ?? 700
        let signedAmount: Int
        switch direction {
        case "up", "left":
            signedAmount = -abs(amount)
        default:
            signedAmount = abs(amount)
        }

        let payload: [String: Any] = [
            "x": direction == "left" || direction == "right" ? signedAmount : 0,
            "y": direction == "up" || direction == "down" ? signedAmount : 0
        ]

        let result = await evaluateAction(scriptName: "scroll", payload: payload, body: Self.scrollScript)
        await settleBriefly()
        return "\(result)\n\(await snapshot())"
    }

    private func wait(_ command: WebControlAgentCommand) async -> String {
        let seconds = min(max(command.seconds ?? 1.0, 0.2), 8.0)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return "Waited \(String(format: "%.1f", seconds)) seconds.\n\(await snapshot())"
    }

    private func navigate(_ command: WebControlAgentCommand) async -> String {
        guard let rawURL = command.url, !rawURL.isEmpty else {
            return "Navigate failed: missing URL.\n\(await snapshot())"
        }

        guard let destination = AddressResolver.url(for: rawURL) else {
            return "Navigate failed: invalid URL \(rawURL).\n\(await snapshot())"
        }

        tab.navigate(to: destination.absoluteString)
        await waitForLoad()
        return "Navigated to \(destination.absoluteString).\n\(await snapshot())"
    }

    private func evaluateAction(scriptName: String, payload: [String: Any], body: String) async -> String {
        guard let payload = Self.jsonLiteral(payload) else {
            return "\(scriptName) failed: could not encode action payload."
        }

        let script = """
        (() => {
            const payload = \(payload);
            \(Self.domHelperScript)
            \(body)
        })();
        """

        do {
            let raw = try await tab.webView.evaluateJavaScript(script)
            if let string = raw as? String, !string.isEmpty {
                return string
            }
            return "\(scriptName) completed without a message."
        } catch {
            return "\(scriptName) failed: \(error.localizedDescription)"
        }
    }

    private func settleBriefly() async {
        try? await Task.sleep(nanoseconds: 650_000_000)
        await waitForLoad(maxSeconds: 6.0)
    }

    private func waitForLoad(maxSeconds: Double = 12.0) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        repeat {
            if !tab.isLoading {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
    }

    private static func jsonLiteral(_ object: Any) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func snapshotScript(maxTextCharacters: Int, maxElements: Int, maxSignals: Int) -> String {
        """
        (() => {
            \(domHelperScript)
            const clean = (value, max = 240) => {
                const text = String(value || "").replace(/[\\t\\r\\f ]+/g, " ").replace(/\\n\\s*\\n+/g, "\\n").trim();
                return text.length > max ? text.slice(0, max) + "..." : text;
            };
            const roleOf = (el) => clean(el.getAttribute("role"), 80);
            const labelOf = (el) => {
                const aria = clean(el.getAttribute("aria-label"), 180);
                if (aria) return aria;
                const labelledBy = el.getAttribute("aria-labelledby");
                if (labelledBy) {
                    const label = labelledBy.split(/\\s+/).map(id => document.getElementById(id)?.innerText || "").join(" ");
                    const cleaned = clean(label, 180);
                    if (cleaned) return cleaned;
                }
                if (el.labels && el.labels.length) {
                    const label = Array.from(el.labels).map(l => l.innerText || "").join(" ");
                    const cleaned = clean(label, 180);
                    if (cleaned) return cleaned;
                }
                return clean(el.getAttribute("title") || el.getAttribute("placeholder") || el.getAttribute("alt"), 180);
            };
            const isInteractive = (el) => {
                const tag = el.tagName.toLowerCase();
                const role = roleOf(el);
                return tag === "a" || tag === "button" || tag === "input" || tag === "textarea" ||
                    tag === "select" || tag === "option" || tag === "summary" ||
                    el.isContentEditable ||
                    ["button", "link", "textbox", "checkbox", "radio", "combobox", "menuitem", "option", "switch", "tab", "searchbox"].includes(role) ||
                    el.hasAttribute("onclick") ||
                    (el.hasAttribute("tabindex") && el.getAttribute("tabindex") !== "-1");
            };
            const elementRecord = (el) => {
                const rect = el.getBoundingClientRect();
                const id = ensureAgentId(el);
                return {
                    id,
                    tag: el.tagName.toLowerCase(),
                    role: roleOf(el),
                    type: clean(el.getAttribute("type"), 60),
                    label: labelOf(el),
                    text: clean(el.innerText || el.textContent, 220),
                    value: clean((el.value !== undefined ? el.value : ""), 160),
                    placeholder: clean(el.getAttribute("placeholder"), 120),
                    href: clean(el.href || el.getAttribute("href"), 240),
                    disabled: !!(el.disabled || el.getAttribute("aria-disabled") === "true"),
                    checked: !!el.checked,
                    selected: !!el.selected,
                    rect: {
                        x: Math.round(rect.x),
                        y: Math.round(rect.y),
                        w: Math.round(rect.width),
                        h: Math.round(rect.height)
                    }
                };
            };
            const signalRecord = (el) => ({
                tag: el.tagName.toLowerCase(),
                role: roleOf(el),
                label: labelOf(el),
                text: clean(el.innerText || el.textContent, 260),
                ariaLive: clean(el.getAttribute("aria-live"), 60),
                dataState: clean(el.getAttribute("data-state") || el.getAttribute("data-status") || el.getAttribute("evaluation"), 80),
                className: clean(typeof el.className === "string" ? el.className : "", 120)
            });
            const all = allElements(document).filter(isVisible);
            const elements = all.filter(isInteractive).slice(0, \(maxElements)).map(elementRecord);
            const signalSelectors = [
                "[aria-label]",
                "[aria-live]",
                "[role='status']",
                "[role='alert']",
                "[data-state]",
                "[data-status]",
                "[evaluation]",
                "game-app",
                "game-row",
                "game-tile",
                "game-keyboard",
                "game-modal"
            ];
            const signalMatches = new Set();
            for (const selector of signalSelectors) {
                for (const rootEl of all) {
                    if (rootEl.matches && rootEl.matches(selector)) signalMatches.add(rootEl);
                }
            }
            const signals = Array.from(signalMatches)
                .filter(el => !isInteractive(el))
                .slice(0, \(maxSignals))
                .map(signalRecord)
                .filter(item => item.label || item.text || item.dataState || item.ariaLive);
            const active = document.activeElement ? {
                tag: document.activeElement.tagName.toLowerCase(),
                id: document.activeElement.getAttribute(AGENT_ATTR) || "",
                label: labelOf(document.activeElement),
                text: clean(document.activeElement.innerText || document.activeElement.textContent, 140)
            } : null;
            const bodyText = clean(document.body ? document.body.innerText : "", \(maxTextCharacters));
            return JSON.stringify({
                title: document.title || "",
                url: location.href,
                activeElement: active,
                viewport: { width: window.innerWidth, height: window.innerHeight, scrollY: Math.round(window.scrollY) },
                text: bodyText,
                elements,
                signals
            });
        })();
        """
    }

    private static let domHelperScript = """
    const AGENT_ATTR = "data-thebrowser-agent-id";
    const allElements = (root) => {
        const out = [];
        const visit = (node) => {
            if (!node || !node.querySelectorAll) return;
            for (const el of node.querySelectorAll("*")) {
                out.push(el);
                if (el.shadowRoot) visit(el.shadowRoot);
            }
        };
        visit(root);
        return out;
    };
    const isVisible = (el) => {
        const style = getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
    };
    const ensureAgentId = (el) => {
        let id = el.getAttribute(AGENT_ATTR);
        if (!id) {
            id = "wca-" + Math.random().toString(36).slice(2, 9);
            el.setAttribute(AGENT_ATTR, id);
        }
        return id;
    };
    const findByAgentId = (id) => {
        if (!id) return null;
        for (const el of allElements(document)) {
            if (el.getAttribute && el.getAttribute(AGENT_ATTR) === id) return el;
        }
        return null;
    };
    const findTarget = (payload) => {
        if (payload.id) {
            const byId = findByAgentId(payload.id);
            if (byId) return byId;
        }
        if (payload.selector) {
            try { return document.querySelector(payload.selector); } catch (_) { return null; }
        }
        return null;
    };
    const describe = (el) => {
        if (!el) return "missing element";
        const label = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("placeholder") || el.innerText || el.textContent || el.tagName;
        return String(label).replace(/\\s+/g, " ").trim().slice(0, 160);
    };
    const mouseEvent = (type, el) => {
        const rect = el.getBoundingClientRect();
        return new MouseEvent(type, {
            bubbles: true,
            cancelable: true,
            composed: true,
            view: window,
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height / 2
        });
    };
    const keyCodeFor = (key) => {
        if (!key) return 0;
        if (key.length === 1) return key.toUpperCase().charCodeAt(0);
        const map = { Enter: 13, Backspace: 8, Tab: 9, Escape: 27, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Space: 32 };
        return map[key] || 0;
    };
    """

    private static let clickScript = """
    const el = findTarget(payload);
    if (!el) return "Click failed: element not found.";
    el.scrollIntoView({ block: "center", inline: "center" });
    el.focus && el.focus({ preventScroll: true });
    ["mouseover", "mousemove", "mousedown", "mouseup"].forEach(type => el.dispatchEvent(mouseEvent(type, el)));
    if (typeof el.click === "function") {
        el.click();
    } else {
        el.dispatchEvent(mouseEvent("click", el));
    }
    return "Clicked: " + describe(el);
    """

    private static let typeScript = """
    const el = findTarget(payload) || document.activeElement;
    if (!el) return "Type failed: element not found and no active element.";
    el.scrollIntoView && el.scrollIntoView({ block: "center", inline: "center" });
    el.focus && el.focus({ preventScroll: true });
    const text = String(payload.text || "");
    const clear = !!payload.clear;
    const tag = el.tagName ? el.tagName.toLowerCase() : "";
    if (tag === "select") {
        const option = Array.from(el.options).find(opt => opt.value === text || opt.text.trim() === text);
        if (!option) return "Type failed: no matching select option for " + text;
        el.value = option.value;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return "Selected option: " + option.text;
    }
    if (el.isContentEditable) {
        if (clear) el.textContent = "";
        document.execCommand("insertText", false, text);
        el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        return "Typed into editable element: " + describe(el);
    }
    if ("value" in el) {
        const proto = tag === "textarea" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
        const next = clear ? text : String(el.value || "") + text;
        if (descriptor && descriptor.set) {
            descriptor.set.call(el, next);
        } else {
            el.value = next;
        }
        el.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text }));
        el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return "Typed into: " + describe(el);
    }
    return "Type failed: target does not accept text.";
    """

    private static let pressKeyScript = """
    const key = String(payload.key || "");
    if (!key) return "Press key failed: missing key.";
    const target = document.activeElement || document.body || document.documentElement;
    const code = keyCodeFor(key);
    const dispatch = (dest, type) => {
        const event = new KeyboardEvent(type, {
            key,
            code: key.length === 1 ? "Key" + key.toUpperCase() : key,
            keyCode: code,
            which: code,
            bubbles: true,
            cancelable: true,
            composed: true
        });
        dest.dispatchEvent(event);
    };
    ["keydown", "keypress", "keyup"].forEach(type => dispatch(target, type));
    ["keydown", "keypress", "keyup"].forEach(type => dispatch(document, type));
    ["keydown", "keypress", "keyup"].forEach(type => dispatch(window, type));
    return "Pressed key: " + key;
    """

    private static let scrollScript = """
    window.scrollBy({ left: Number(payload.x || 0), top: Number(payload.y || 0), behavior: "smooth" });
    return "Scrolled by x=" + Number(payload.x || 0) + ", y=" + Number(payload.y || 0);
    """
}
