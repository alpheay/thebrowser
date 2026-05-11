import SwiftUI

// MARK: - Pending attachment chip (composer)

/// Larger chip rendered above the composer for a highlight the user has
/// queued for the next chat turn. Designed to read as "card with a remove
/// X" rather than a button — the user is in editing mode, not sending yet.
struct PendingAttachmentChip: View {
    let attachment: ChatAttachment
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            sourceGlyph

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(attachment.preview)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isHovering ? Palette.surfaceActive : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove highlight")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovering ? Palette.surfaceHover : Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            // A subtle quote-rail on the leading edge — same visual language
            // as a Markdown blockquote without painting the chip yellow.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Palette.textFaint)
                .frame(width: 2)
                .padding(.vertical, 6)
                .padding(.leading, 1)
        }
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(attachment.preview)
    }

    @ViewBuilder
    private var sourceGlyph: some View {
        if let host = attachment.host, !host.isEmpty {
            FaviconView(host: host)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
        } else {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
        }
    }
}

// MARK: - Sent attachment chip (user bubble)

/// Compact, read-only chip rendered above a user message bubble for each
/// highlight the user attached when they sent the message. Smaller and
/// quieter than the pending chip — it's history, not pending edit state.
struct SentAttachmentChip: View {
    let attachment: ChatAttachment

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let host = attachment.host, !host.isEmpty {
                FaviconView(host: host)
                    .frame(width: 11, height: 11)
            } else {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 11, height: 11)
            }

            Text(attachment.displayLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("·")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.textFaint)

            Text(attachment.preview)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(isHovering ? Palette.surfaceHover : Palette.surface)
        }
        .overlay {
            Capsule().stroke(Palette.stroke, lineWidth: 1)
        }
        .frame(maxWidth: 270, alignment: .trailing)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(attachment.preview)
    }
}
