import SwiftUI

/// A single notification toast. Matches the matte black surface aesthetic
/// used by `SmartReadCard` and the chat bubbles — `Palette.surface` plate,
/// hairline stroke, monochrome typography, soft shadow for lift.
struct NotificationToast: View {
    let notification: AppNotification
    var onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            iconBadge

            VStack(alignment: .leading, spacing: notification.message == nil ? 0 : 3) {
                Text(notification.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = notification.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .lineSpacing(1.5)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let label = notification.actionLabel {
                    actionButton(label: label)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            closeButton
                .opacity(isHovering ? 1 : 0)
                .animation(Motion.hoverFade, value: isHovering)
        }
        .padding(.vertical, 11)
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .frame(width: 332, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                AppNotificationCenter.shared.pauseDismiss(for: notification.id)
            } else {
                AppNotificationCenter.shared.resumeDismiss(for: notification.id)
            }
        }
    }

    // MARK: - Icon

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.bgRaised)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
            Image(systemName: notification.resolvedIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notification.kind.accent)
        }
        .frame(width: 28, height: 28)
    }

    // MARK: - Action button

    private func actionButton(label: String) -> some View {
        Button {
            notification.action?()
            onDismiss()
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.bg)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Close button

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.surfaceHover.opacity(0.6))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}
