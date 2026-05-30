import SwiftUI

/// Small, colored AI-label pill shown on a message row and in the filter bar.
struct AILabelTag: View {
    let label: AILabel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(label.color)
                .frame(width: 6, height: 6)
            if !compact {
                Text(label.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(label.color.opacity(0.14))
        )
        .overlay(
            Capsule().stroke(label.color.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Horizontal filter bar of AI labels above the message list. Tapping a label
/// scopes the list to it; tapping again clears. Also surfaces a "Needs reply"
/// filter backed by the reminder store.
struct MailLabelFilterBar: View {
    @ObservedObject var mail: MailModel
    @Binding var selectedLabelID: String?
    @Binding var needsReplyOnly: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                needsReplyChip

                ForEach(visibleLabels) { label in
                    filterChip(
                        title: "\(label.name)\(countSuffix(for: label.id))",
                        color: label.color,
                        selected: selectedLabelID == label.id
                    ) {
                        toggle(label.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Only labels that actually appear on the current message set, so the bar
    /// stays relevant instead of listing every possible label.
    private var visibleLabels: [AILabel] {
        let counts = mail.triage.counts()
        return mail.triage.labels.filter { ($0.enabled && counts[$0.id, default: 0] > 0) || selectedLabelID == $0.id }
    }

    private func countSuffix(for id: String) -> String {
        let n = mail.triage.counts()[id, default: 0]
        return n > 0 ? " \(n)" : ""
    }

    private var needsReplyChip: some View {
        let count = mail.reminders.reminderThreadIDs.count
        return filterChip(
            title: count > 0 ? "Needs reply \(count)" : "Needs reply",
            color: Palette.accent,
            selected: needsReplyOnly,
            systemImage: "clock.badge.exclamationmark"
        ) {
            withAnimation(Motion.springSnap) {
                needsReplyOnly.toggle()
                if needsReplyOnly { selectedLabelID = nil }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(Motion.springSnap) {
            if selectedLabelID == id {
                selectedLabelID = nil
            } else {
                selectedLabelID = id
                needsReplyOnly = false
            }
        }
    }

    private func filterChip(
        title: String,
        color: Color,
        selected: Bool,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? color : Palette.chipBackground)
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : Palette.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
