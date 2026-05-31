import SwiftUI

extension Color {
    /// Builds a color from an `AILabel.colorHex` string ("F2C14E").
    init(mailHex: String) {
        let cleaned = mailHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt(cleaned, radix: 16) ?? 0x9B9B9B)
    }
}

/// A monochrome initials avatar — scannable identity without breaking the
/// app's strict no-color palette.
struct MailAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 32
    var unread: Bool = false

    private var initials: String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? email : name
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        if letters.isEmpty { return source.first.map { String($0).uppercased() } ?? "?" }
        return letters.joined().uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(unread ? Palette.textPrimary : Palette.textSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(unread ? Palette.surfaceActive : Palette.surface))
            .overlay(Circle().stroke(Palette.stroke, lineWidth: 1))
    }
}

/// A row in the inbox navigation rail: an icon or colored label-dot, a title,
/// an optional trailing count, and selected/hover states.
struct MailNavRow: View {
    var icon: String? = nil
    var dotColor: Color? = nil
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 8, height: 8).frame(width: 16)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textMuted)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selected ? Palette.textSecondary : Palette.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Palette.surfaceActive : (hovering ? Palette.surfaceHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hoverFade, value: hovering)
    }
}

/// A small pill toggle for the inbox quick filters (All / Unread / Starred).
struct MailFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(selected ? Palette.accent : (hovering ? Palette.surfaceHover : Palette.bgRaised)))
                .overlay(Capsule().stroke(selected ? Color.clear : Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hoverFade, value: hovering)
    }
}

/// A compact colored pill for an AI triage label.
struct AILabelTag: View {
    let label: AILabel
    var body: some View {
        let color = Color(mailHex: label.colorHex)
        Text(label.name)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.40), lineWidth: 0.5))
    }
}

/// Renders the AI labels attached to a message as a row of pills.
struct AILabelRow: View {
    let labels: [AILabel]
    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels) { AILabelTag(label: $0) }
            }
        }
    }
}

/// A consent affordance for an auto-extracted memory ("Remember this?").
struct MemorySuggestionToast: View {
    let memory: MailMemory
    let onKeep: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Remember this?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(memory.text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(memory.kind.label) · \(memory.anchor.label)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                HStack(spacing: 8) {
                    Button("Keep", action: onKeep).buttonStyle(PillButtonStyle())
                    Button("Dismiss", action: onDismiss).buttonStyle(PillButtonStyle())
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .surfaceCard()
    }
}

/// A small banner summarizing follow-up reminders that are due.
struct MailRemindersBanner: View {
    let reminders: [MailReminder]
    let onOpen: (MailReminder) -> Void
    let onDismiss: (MailReminder) -> Void

    var body: some View {
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.35))
                    Text("Follow-ups (\(reminders.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(reminders.prefix(4)) { reminder in
                    HStack(spacing: 8) {
                        Button { onOpen(reminder) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reminder.subject.isEmpty ? "(no subject)" : reminder.subject)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                if let note = reminder.note {
                                    Text(note)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Palette.textMuted)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button { onDismiss(reminder) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.stroke, lineWidth: 1))
        }
    }
}
