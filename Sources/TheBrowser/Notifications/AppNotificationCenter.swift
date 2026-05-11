import Foundation
import SwiftUI

/// App-wide notification queue. Any service can call `post(...)` from the
/// main actor and the toast will appear in the corner the user picked in
/// Settings → General.
///
/// The center keeps up to `maxVisible` toasts on screen at once; extra
/// posts queue and slot in as visible toasts dismiss. Each visible toast
/// auto-dismisses after its `duration` unless the user hovers (the
/// overlay extends the timer for hovered toasts) or the action button
/// dismisses it explicitly.
@MainActor
final class AppNotificationCenter: ObservableObject {
    static let shared = AppNotificationCenter()

    @Published private(set) var visible: [AppNotification] = []
    @Published private(set) var queued: [AppNotification] = []

    private let maxVisible = 3
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Posting

    /// Enqueue a fully-built notification.
    func post(_ notification: AppNotification) {
        if visible.count < maxVisible {
            present(notification)
        } else {
            queued.append(notification)
        }
    }

    /// Convenience for the common case.
    @discardableResult
    func post(
        title: String,
        message: String? = nil,
        icon: String? = nil,
        kind: AppNotificationKind = .info,
        duration: TimeInterval = 4.5,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) -> UUID {
        let notification = AppNotification(
            title: title,
            message: message,
            icon: icon,
            kind: kind,
            duration: duration,
            actionLabel: actionLabel,
            action: action
        )
        post(notification)
        return notification.id
    }

    // MARK: - Dismissal

    func dismiss(_ id: UUID) {
        dismissTasks.removeValue(forKey: id)?.cancel()

        if let index = visible.firstIndex(where: { $0.id == id }) {
            visible.remove(at: index)
            promoteNextIfNeeded()
            return
        }

        queued.removeAll { $0.id == id }
    }

    func dismissAll() {
        for (_, task) in dismissTasks { task.cancel() }
        dismissTasks.removeAll()
        visible.removeAll()
        queued.removeAll()
    }

    // MARK: - Hover hooks

    /// Pauses the auto-dismiss timer for a hovered toast so the user can
    /// read it. The overlay calls this from `.onHover`.
    func pauseDismiss(for id: UUID) {
        dismissTasks.removeValue(forKey: id)?.cancel()
    }

    /// Resumes the auto-dismiss with a fresh duration when hover ends.
    func resumeDismiss(for id: UUID) {
        guard let notification = visible.first(where: { $0.id == id }) else { return }
        scheduleDismiss(for: notification.id, after: notification.duration)
    }

    // MARK: - Internals

    private func present(_ notification: AppNotification) {
        visible.append(notification)
        scheduleDismiss(for: notification.id, after: notification.duration)
    }

    private func scheduleDismiss(for id: UUID, after duration: TimeInterval) {
        dismissTasks.removeValue(forKey: id)?.cancel()
        guard duration > 0 else { return }
        let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.dismiss(id)
        }
        dismissTasks[id] = task
    }

    private func promoteNextIfNeeded() {
        while visible.count < maxVisible, !queued.isEmpty {
            let next = queued.removeFirst()
            present(next)
        }
    }
}
