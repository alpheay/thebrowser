import Foundation
import SwiftUI

enum AppNotificationKind: String, CaseIterable, Sendable {
    case info
    case success
    case warning
    case error

    var defaultIcon: String {
        switch self {
        case .info: return "sparkles"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var accent: Color {
        // The whole UI is monochrome; we tint the icon ring subtly per kind
        // so the type is legible without breaking the matte aesthetic.
        switch self {
        case .info: return Color.white.opacity(0.85)
        case .success: return Color.white
        case .warning: return Color(red: 0.98, green: 0.82, blue: 0.45)
        case .error: return Color(red: 1.0, green: 0.55, blue: 0.55)
        }
    }
}

/// A single notification ready to display. Use the conveniences on
/// `AppNotificationCenter` rather than building this directly when possible.
struct AppNotification: Identifiable, Equatable {
    let id: UUID
    var title: String
    var message: String?
    var icon: String?
    var kind: AppNotificationKind
    var duration: TimeInterval
    var actionLabel: String?
    var action: (@MainActor () -> Void)?

    init(
        id: UUID = UUID(),
        title: String,
        message: String? = nil,
        icon: String? = nil,
        kind: AppNotificationKind = .info,
        duration: TimeInterval = 4.5,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.icon = icon
        self.kind = kind
        self.duration = duration
        self.actionLabel = actionLabel
        self.action = action
    }

    var resolvedIcon: String { icon ?? kind.defaultIcon }

    static func == (lhs: AppNotification, rhs: AppNotification) -> Bool {
        lhs.id == rhs.id
    }
}

/// Where the notification stack anchors inside the window. Persisted in
/// `UserDefaults` under `PreferenceKey.notificationCorner` and exposed in
/// Settings → General.
enum NotificationCorner: String, CaseIterable, Identifiable, Sendable {
    case topRight
    case topLeft
    case bottomRight
    case bottomLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        }
    }

    var isTop: Bool {
        self == .topRight || self == .topLeft
    }

    var isTrailing: Bool {
        self == .topRight || self == .bottomRight
    }

    /// Edge a new toast slides in from.
    var entryEdge: Edge {
        isTrailing ? .trailing : .leading
    }
}
