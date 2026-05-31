import Foundation

/// Which surface the user is currently looking at. Injected at the very top of
/// every agent prompt so the assistant orients itself before reaching for
/// tools — e.g. it must not "open the inbox" or "search mail" when the user is
/// already reading a specific email. Four states, matching the app's surfaces:
/// the web browser, the mail inbox, the artifact gallery, and Discord.
enum ChatFocus: Equatable, Sendable {
    case browser
    case mail
    case artifacts
    case discord

    /// The "CURRENT SURFACE" block for the prompt. For mail it folds in the
    /// live open-email / compose-draft detail from ``MailContext``.
    @MainActor
    func promptBlock(gmail: GmailStore, mail: MailModel) -> String? {
        switch self {
        case .mail:
            let detail = MailContext.promptBlock(gmail: gmail, mail: mail) ?? "The inbox is open."
            return "CURRENT SURFACE — MAIL. The user is in their email inbox (not on a web page).\n\(detail)"
        case .artifacts:
            return "CURRENT SURFACE — ARTIFACTS. The user is viewing the artifact gallery (saved AI-generated HTML documents), not mail or a normal web page."
        case .discord:
            return "CURRENT SURFACE — DISCORD. The user has the Discord window open."
        case .browser:
            return "CURRENT SURFACE — BROWSER. The user is on a web page (see Current tab below). Use the web tools (open/search/fetch/read_tabs/web_control). The inbox is not open — call mail_show first if they ask to see mail."
        }
    }
}
