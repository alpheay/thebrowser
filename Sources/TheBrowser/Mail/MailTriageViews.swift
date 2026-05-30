import SwiftUI

extension Color {
    /// Builds a color from an `AILabel.colorHex` string ("F2C14E").
    init(mailHex: String) {
        let cleaned = mailHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt(cleaned, radix: 16) ?? 0x9B9B9B)
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
