import AppKit
import SwiftUI

/// Full-window history browser. Two-pane layout: left rail of date groups
/// (Today / Yesterday / This Week / Older) acts as a quick filter; right
/// pane is a flat list of visits with favicon, title, URL, and time.
/// Real-time search filters across title + URL.
@MainActor
struct HistoryModalView: View {
    /// Closes the modal. Wired to the toolbar X button and the Escape key.
    let onClose: () -> Void
    /// Navigates the active tab to `url`. Wired to a left-click on a row.
    let onOpen: (URL) -> Void
    /// Opens `url` in a fresh background tab. Wired to ⌘-click on a row.
    let onOpenInBackgroundTab: (URL) -> Void

    @State private var entries: [HistoryEntry] = []
    @State private var selectedGroup: HistoryDateGroup = .today
    @State private var query: String = ""
    @State private var isLoaded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)

            HStack(spacing: 0) {
                groupRail
                    .frame(width: 220)
                    .frame(maxHeight: .infinity)
                    .background(Palette.bgSunken)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Palette.stroke)
                            .frame(width: 1)
                    }

                visitList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reload()
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            reload()
        }
        .background {
            // Esc handler — picks up unmodified key presses, which the
            // shell-level KeyboardShortcutHost ignores.
            HistoryEscapeHandler(onEscape: onClose)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer(minLength: 16)

            searchField

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("Close history")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        let total = entries.count
        if total == 0 { return "Nothing here yet — pages you visit will appear in this list." }
        if total == 1 { return "1 page in your timeline." }
        return "\(total) pages in your timeline."
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            TextField("Search title or URL", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 320, height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchFocused ? Color.white.opacity(0.18) : Palette.stroke, lineWidth: 1)
                .animation(.easeOut(duration: 0.12), value: searchFocused)
        }
    }

    // MARK: - Group rail

    private var groupRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WHEN")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 12)

            ForEach(HistoryDateGroup.allCases) { group in
                groupRow(group)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func groupRow(_ group: HistoryDateGroup) -> some View {
        let count = countByGroup[group, default: 0]
        let isSelected = selectedGroup == group && trimmedQuery.isEmpty
        return Button {
            withAnimation(Motion.springSnap) {
                selectedGroup = group
                query = ""
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                    .frame(width: 16)
                Text(group.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.hoverFade, value: isSelected)
    }

    // MARK: - Visit list

    @ViewBuilder
    private var visitList: some View {
        let visible = filteredEntries
        if !isLoaded {
            Color.clear
        } else if visible.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle()
                                .fill(Palette.strokeFaint)
                                .frame(height: 1)
                                .padding(.leading, 56)
                        }
                        HistoryRowView(
                            entry: entry,
                            onOpen: { handleOpen(entry, modifierFlags: NSApp.currentEvent?.modifierFlags ?? []) },
                            onOpenInBackground: { onOpenInBackgroundTab(entry.url) },
                            onDelete: { delete(entry) },
                            onForgetSite: { forgetSite(of: entry) }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: trimmedQuery.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text(trimmedQuery.isEmpty ? "Nothing in this range yet." : "No matches for \u{201C}\(trimmedQuery)\u{201D}.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }

    // MARK: - Actions

    private func reload() {
        entries = HistoryStore.shared.listHistory(limit: 5_000)
        isLoaded = true
    }

    private func handleOpen(_ entry: HistoryEntry, modifierFlags: NSEvent.ModifierFlags) {
        if modifierFlags.contains(.command) {
            onOpenInBackgroundTab(entry.url)
        } else {
            onOpen(entry.url)
        }
    }

    private func delete(_ entry: HistoryEntry) {
        HistoryStore.shared.deleteEntry(id: entry.id)
        // Optimistic — the notification reload will reconcile if anything
        // else changed in the meantime.
        entries.removeAll { $0.id == entry.id }
    }

    private func forgetSite(of entry: HistoryEntry) {
        guard let host = entry.host else { return }
        HistoryStore.shared.deleteEntries(host: host)
        let normalized = host.lowercased()
        entries.removeAll { entry in
            guard let entryHost = entry.url.host(percentEncoded: false)?.lowercased() else { return false }
            return entryHost == normalized || entryHost.hasSuffix(".\(normalized)") || normalized.hasSuffix(".\(entryHost)")
        }
    }

    // MARK: - Derived data

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When the user is searching, ignore the date filter and just match
    /// across the entire log. This matches the Chrome / Arc convention.
    private var filteredEntries: [HistoryEntry] {
        if !trimmedQuery.isEmpty {
            let lower = trimmedQuery.lowercased()
            return entries.filter { entry in
                entry.title.lowercased().contains(lower) ||
                entry.url.absoluteString.lowercased().contains(lower)
            }
        }
        return entries.filter { selectedGroup.contains($0.lastVisitedAt) }
    }

    private var countByGroup: [HistoryDateGroup: Int] {
        var counts: [HistoryDateGroup: Int] = [:]
        let now = Date()
        for entry in entries {
            for group in HistoryDateGroup.allCases where group.contains(entry.lastVisitedAt, now: now) {
                counts[group, default: 0] += 1
                break
            }
        }
        return counts
    }
}

// MARK: - Date groups

enum HistoryDateGroup: String, CaseIterable, Identifiable, Hashable {
    case today
    case yesterday
    case thisWeek
    case older

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This Week"
        case .older: "Older"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .yesterday: "moon"
        case .thisWeek: "calendar"
        case .older: "archivebox"
        }
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.isDateInToday(date)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .thisWeek:
            // Last 7 days, excluding today and yesterday.
            guard !calendar.isDateInToday(date), !calendar.isDateInYesterday(date) else { return false }
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) else {
                return false
            }
            return date >= cutoff
        case .older:
            guard !calendar.isDateInToday(date), !calendar.isDateInYesterday(date) else { return false }
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) else {
                return false
            }
            return date < cutoff
        }
    }
}

// MARK: - Row

private struct HistoryRowView: View {
    let entry: HistoryEntry
    let onOpen: () -> Void
    let onOpenInBackground: () -> Void
    let onDelete: () -> Void
    let onForgetSite: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                FaviconBadge(host: entry.host)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.url.absoluteString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if entry.visitCount > 1 {
                    Text("\u{00D7}\(entry.visitCount)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.textFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Palette.bgRaised)
                        }
                }

                Text(timeLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 88, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover.opacity(0.55) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .contextMenu {
            Button("Open in new tab") { onOpenInBackground() }
            if let host = entry.host, let url = URL(string: "https://\(host)") {
                Button("Visit site") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Copy link") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Delete entry", role: .destructive) { onDelete() }
            if entry.host != nil {
                Button("Forget all visits to this site", role: .destructive) { onForgetSite() }
            }
        }
    }

    private var timeLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.lastVisitedAt) {
            return Self.timeOnly.string(from: entry.lastVisitedAt)
        } else if calendar.isDateInYesterday(entry.lastVisitedAt) {
            return "yest \u{00B7} " + Self.timeOnly.string(from: entry.lastVisitedAt)
        }
        return Self.dayAndTime.string(from: entry.lastVisitedAt)
    }

    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()
}

private struct FaviconBadge: View {
    let host: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.surface)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
            if let host {
                FaviconView(host: host)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }
}

// MARK: - Esc-to-dismiss bridge

/// Captures unmodified Escape key presses while the modal is on screen.
/// `KeyboardShortcutHost` skips events without a modifier, so the modal
/// owns its own dismissal monitor.
private struct HistoryEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(onEscape: @escaping () -> Void) {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    onEscape()
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
