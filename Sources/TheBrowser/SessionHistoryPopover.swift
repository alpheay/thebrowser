import SwiftUI

/// Compact picker of recent chat sessions, anchored to the chat header's
/// history button. Loads its data lazily in `.task` so the popover paints
/// before the file enumeration runs.
struct SessionHistoryPopover: View {
    let currentSessionID: String
    let onPick: (String) -> Void

    @State private var summaries: [SessionSummary] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
            content
        }
        .frame(width: 320, height: 420)
        .background(Palette.bg)
        .task {
            summaries = ChatSessionStore.shared
                .listSessions()
                .filter { $0.id != currentSessionID }
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("RECENT CONVERSATIONS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Color.clear
        } else if summaries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 {
                            Rectangle()
                                .fill(Palette.strokeFaint)
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                        }
                        SessionHistoryRow(summary: summary) {
                            onPick(summary.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "clock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text("No previous conversations")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }
}

private struct SessionHistoryRow: View {
    let summary: SessionSummary
    let onPick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.hoverFade) { isHovering = hovering }
        }
        .help(summary.firstUserMessage ?? title)
    }

    private var title: String {
        let pageTitle = summary.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageTitle.isEmpty {
            return pageTitle
        }
        if let snippet = trimmedFirstMessage, !snippet.isEmpty {
            return snippet
        }
        return "Untitled conversation"
    }

    private var subtitle: String {
        let when = Self.relativeFormatter.localizedString(for: summary.updatedAt, relativeTo: Date())
        let hasPageTitle = !summary.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPageTitle, let snippet = trimmedFirstMessage, !snippet.isEmpty {
            return "\(when) · \(snippet)"
        }
        return when
    }

    private var trimmedFirstMessage: String? {
        guard let msg = summary.firstUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return nil }
        let collapsed = msg.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
