import Combine
import Foundation

/// Catalogue of integrations the overlay can host. Each integration is a
/// self-contained module under ``Sources/TheBrowser/Integrations`` so they
/// can be added or removed without touching the surrounding browser.
enum IntegrationKind: String, CaseIterable, Identifiable, Sendable {
    case gmail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        }
    }

    /// Short blurb shown in the launcher row.
    var subtitle: String {
        switch self {
        case .gmail: "Inbox, search, and quick compose"
        }
    }

    /// SF Symbol used when no integration-specific glyph exists.
    var symbolName: String {
        switch self {
        case .gmail: "envelope.fill"
        }
    }
}

/// Single source of truth for whether the integrations overlay is on screen
/// and, if so, which integration is selected. The browser shell observes
/// this and decides whether to dim and render the overlay.
@MainActor
final class IntegrationsModel: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var activeIntegration: IntegrationKind? = nil

    /// Toggles the overlay, opening directly to `kind` (defaulting to Gmail
    /// — the only integration today). Re-using the shortcut while the
    /// overlay is open closes it so it feels lightweight.
    func toggle(to kind: IntegrationKind = .gmail) {
        if isPresented {
            close()
        } else {
            open(kind)
        }
    }

    func open(_ kind: IntegrationKind) {
        activeIntegration = kind
        isPresented = true
    }

    func close() {
        isPresented = false
    }
}
