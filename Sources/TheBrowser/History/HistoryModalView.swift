import AppKit
import SwiftUI

/// Full-window history browser. The layout reads top-down:
///
/// * **Hero** — display title, tally chip, close button, and a wide
///   centered search field with kind-filter pills underneath.
/// * **Body** — a slim left rail of date groups and a right pane of
///   visits broken up by inline section headers (time-of-day on Today /
///   Yesterday, day name on This Week, month on Older).
///
/// Search rows (queries the user typed into the URL bar) live alongside
/// page visits in the same list; the row chrome adapts so they read
/// naturally next to each other. Clicking a search row re-runs the query
/// instead of opening a URL — see ``onOpenSearch``.
@MainActor
struct HistoryModalView: View {
    /// Closes the modal. Wired to the toolbar X button and the Escape key.
    let onClose: () -> Void
    /// Navigates the active tab to `url`. Wired to a left-click on a row.
    let onOpen: (URL) -> Void
    /// Opens `url` in a fresh background tab. Wired to ⌘-click on a row.
    let onOpenInBackgroundTab: (URL) -> Void
    /// Re-runs the user's search query in the active tab. Wired to a
    /// left-click on a search row.
    let onOpenSearch: (String) -> Void

    @State private var entries: [HistoryEntry] = []
    @State private var selectedGroup: HistoryDateGroup = .today
    @State private var selectedKind: HistoryKindFilter = .all
    @State private var query: String = ""
    @State private var isLoaded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                hero

                Rectangle()
                    .fill(Palette.strokeFaint)
                    .frame(height: 1)

                HStack(spacing: 0) {
                    groupRail
                        .frame(width: 200)
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(Palette.strokeFaint)
                        .frame(width: 1)

                    timeline
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reload()
            DispatchQueue.main.async { searchFocused = true }
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

    // MARK: - Backdrop

    /// Quiet vertical gradient so the hero floats over a slightly lighter
    /// plate than the body. The gradient stops are still in the matte
    /// black range — the eye reads it as a single surface with depth.
    private var backdrop: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: Color(hex: 0x141414), location: 0),
                Gradient.Stop(color: Palette.bg, location: 0.34),
                Gradient.Stop(color: Palette.bg, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }

                Spacer(minLength: 16)

                if !entries.isEmpty {
                    HistoryStatChip(count: entries.count)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Close history")
            }
            .padding(.horizontal, 28)

            searchField
                .padding(.horizontal, 28)

            kindPills
                .padding(.horizontal, 28)
        }
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var headerSubtitle: String {
        if entries.isEmpty {
            return "Pages you visit and searches you run will appear here."
        }
        let visits = entries.filter { !$0.isSearch }.count
        let searches = entries.filter(\.isSearch).count
        var parts: [String] = []
        if visits > 0 { parts.append("\(visits) " + (visits == 1 ? "page" : "pages")) }
        if searches > 0 { parts.append("\(searches) " + (searches == 1 ? "search" : "searches")) }
        if parts.isEmpty { return "Empty." }
        return parts.joined(separator: " \u{00B7} ") + " in your timeline."
    }

    /// Wide, centered, Spotlight-flavoured input. Doubles its glow on
    /// focus so it reads as the modal's first input affordance.
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchFocused ? Palette.textPrimary : Palette.textMuted)
            TextField("Search the timeline\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(searchFocused ? Color.white.opacity(0.06) : Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(searchFocused ? Color.white.opacity(0.22) : Palette.stroke, lineWidth: 1)
        }
        .shadow(color: searchFocused ? Color.black.opacity(0.45) : Color.clear, radius: 18, y: 6)
        .animation(Motion.springSnap, value: searchFocused)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var kindPills: some View {
        HStack(spacing: 6) {
            ForEach(HistoryKindFilter.allCases) { filter in
                KindPill(
                    filter: filter,
                    count: countByKind[filter, default: 0],
                    selected: filter == selectedKind,
                    action: {
                        withAnimation(Motion.springSnap) {
                            selectedKind = filter
                        }
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Group rail

    private var groupRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WHEN")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(HistoryDateGroup.allCases) { group in
                    groupRow(group)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .background(Palette.bgSunken.opacity(0.6))
    }

    private func groupRow(_ group: HistoryDateGroup) -> some View {
        let count = countByGroup[group, default: 0]
        let isSelected = selectedGroup == group && trimmedQuery.isEmpty
        return GroupRailCard(
            group: group,
            count: count,
            isSelected: isSelected
        ) {
            withAnimation(Motion.springSnap) {
                selectedGroup = group
                query = ""
            }
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        let sections = visibleSections
        if !isLoaded {
            Color.clear
        } else if sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        if sectionIndex > 0 {
                            Spacer().frame(height: 18)
                        }
                        sectionHeader(section)
                        VStack(spacing: 2) {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { _, entry in
                                HistoryRowView(
                                    entry: entry,
                                    onOpen: { openEntry(entry) },
                                    onOpenInBackground: { onOpenInBackgroundTab(entry.url) },
                                    onDelete: { delete(entry) },
                                    onForgetSite: { forgetSite(of: entry) }
                                )
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.top, 14)
            }
            .scrollIndicators(.automatic)
            .mask {
                // Soft top fade so scrolled content slides under the
                // hero divider instead of clipping hard against it.
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    Rectangle().fill(Color.black)
                }
            }
        }
    }

    private func sectionHeader(_ section: HistoryTimelineSection) -> some View {
        HStack(spacing: 10) {
            if let symbol = section.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 12)
            }
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)
            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)
            Text("\(section.entries.count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Palette.surface)
                    .frame(width: 64, height: 64)
                Circle()
                    .stroke(Palette.stroke, lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: trimmedQuery.isEmpty ? "clock" : "magnifyingglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Palette.textMuted)
            }
            VStack(spacing: 4) {
                Text(emptyTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(emptyHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
    }

    private var emptyTitle: String {
        if !trimmedQuery.isEmpty { return "No matches" }
        switch selectedKind {
        case .all: return selectedGroup.emptyTitle
        case .pages: return "No pages in \(selectedGroup.title.lowercased()) yet"
        case .searches: return "No searches in \(selectedGroup.title.lowercased()) yet"
        }
    }

    private var emptyHint: String {
        if !trimmedQuery.isEmpty {
            return "Try a different keyword or clear the search."
        }
        return selectedKind == .searches
            ? "Anything you type into the URL bar that isn\u{2019}t a link will show up here."
            : "Pick another span on the left, or browse to start filling this in."
    }

    // MARK: - Actions

    private func reload() {
        entries = HistoryStore.shared.listHistory(limit: 5_000)
        if !isLoaded {
            // On first paint, jump to the most recent non-empty group so a
            // fresh DB doesn't land the user on an empty "Today" pane while
            // older imported history sits one click away.
            selectedGroup = mostRecentPopulatedGroup() ?? .today
        }
        isLoaded = true
    }

    private func mostRecentPopulatedGroup() -> HistoryDateGroup? {
        let now = Date()
        for group in HistoryDateGroup.allCases {
            if entries.contains(where: { group.contains($0.lastVisitedAt, now: now) }) {
                return group
            }
        }
        return nil
    }

    private func openEntry(_ entry: HistoryEntry) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command), !entry.isSearch {
            onOpenInBackgroundTab(entry.url)
            return
        }
        if entry.isSearch {
            onOpenSearch(entry.title)
        } else {
            onOpen(entry.url)
        }
    }

    private func delete(_ entry: HistoryEntry) {
        HistoryStore.shared.deleteEntry(id: entry.id)
        entries.removeAll { $0.id == entry.id }
    }

    private func forgetSite(of entry: HistoryEntry) {
        guard let host = entry.host else { return }
        HistoryStore.shared.deleteEntries(host: host)
        let normalized = host.lowercased()
        entries.removeAll { entry in
            guard let entryHost = entry.url.host(percentEncoded: false)?.lowercased() else { return false }
            return entryHost == normalized
                || entryHost.hasSuffix(".\(normalized)")
                || normalized.hasSuffix(".\(entryHost)")
        }
    }

    // MARK: - Derived data

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entries the modal would render, before sectioning. When a query is
    /// present the date filter is ignored so the user can search the full
    /// log; the kind pill still narrows the result set in both modes.
    private var filteredEntries: [HistoryEntry] {
        let kindFiltered: [HistoryEntry]
        switch selectedKind {
        case .all: kindFiltered = entries
        case .pages: kindFiltered = entries.filter { !$0.isSearch }
        case .searches: kindFiltered = entries.filter(\.isSearch)
        }

        if !trimmedQuery.isEmpty {
            let lower = trimmedQuery.lowercased()
            return kindFiltered.filter { entry in
                entry.title.lowercased().contains(lower)
                    || entry.url.absoluteString.lowercased().contains(lower)
            }
        }

        return kindFiltered.filter { selectedGroup.contains($0.lastVisitedAt) }
    }

    /// Filtered entries broken into time-of-day / day-of-week sections.
    /// Search results have one synthetic "Best matches" section since the
    /// date filter doesn't apply.
    private var visibleSections: [HistoryTimelineSection] {
        let visible = filteredEntries
        guard !visible.isEmpty else { return [] }

        if !trimmedQuery.isEmpty {
            return [HistoryTimelineSection(
                id: "search",
                title: "Best matches",
                symbolName: nil,
                entries: visible
            )]
        }
        return HistoryTimelineSectioner.sections(for: visible, in: selectedGroup)
    }

    private var countByGroup: [HistoryDateGroup: Int] {
        var counts: [HistoryDateGroup: Int] = [:]
        let now = Date()
        let kindFiltered: [HistoryEntry]
        switch selectedKind {
        case .all: kindFiltered = entries
        case .pages: kindFiltered = entries.filter { !$0.isSearch }
        case .searches: kindFiltered = entries.filter(\.isSearch)
        }
        for entry in kindFiltered {
            for group in HistoryDateGroup.allCases where group.contains(entry.lastVisitedAt, now: now) {
                counts[group, default: 0] += 1
                break
            }
        }
        return counts
    }

    private var countByKind: [HistoryKindFilter: Int] {
        let total = entries.count
        let searches = entries.filter(\.isSearch).count
        return [
            .all: total,
            .pages: total - searches,
            .searches: searches
        ]
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

    var emptyTitle: String {
        switch self {
        case .today: "Nothing today, yet"
        case .yesterday: "Nothing yesterday"
        case .thisWeek: "Nothing this week"
        case .older: "Nothing older"
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

// MARK: - Kind filter

enum HistoryKindFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case pages
    case searches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pages: "Pages"
        case .searches: "Searches"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "circle.grid.2x2"
        case .pages: "globe"
        case .searches: "magnifyingglass"
        }
    }
}

// MARK: - Timeline sections

/// A heading + the rows that sit under it inside the timeline. `symbolName`
/// is optional so the synthetic "Best matches" search section can omit a
/// glyph while time / weekday / month sections each get a tasteful one.
struct HistoryTimelineSection: Identifiable {
    let id: String
    let title: String
    let symbolName: String?
    let entries: [HistoryEntry]
}

/// Groups entries into headings depending on the active date group:
/// time-of-day chunks for Today/Yesterday, weekday names for This Week,
/// month-year labels for Older. Kept in one place so the modal stays
/// declarative.
enum HistoryTimelineSectioner {
    static func sections(
        for entries: [HistoryEntry],
        in group: HistoryDateGroup,
        now: Date = Date()
    ) -> [HistoryTimelineSection] {
        guard !entries.isEmpty else { return [] }
        switch group {
        case .today, .yesterday:
            return groupByTimeOfDay(entries)
        case .thisWeek:
            return groupByWeekday(entries, now: now)
        case .older:
            return groupByMonth(entries)
        }
    }

    private static func groupByTimeOfDay(_ entries: [HistoryEntry]) -> [HistoryTimelineSection] {
        var buckets: [(TimeBucket, [HistoryEntry])] = TimeBucket.allCases.map { ($0, []) }
        let calendar = Calendar.current
        for entry in entries {
            let hour = calendar.component(.hour, from: entry.lastVisitedAt)
            let bucket = TimeBucket.bucket(forHour: hour)
            if let index = buckets.firstIndex(where: { $0.0 == bucket }) {
                buckets[index].1.append(entry)
            }
        }
        return buckets.compactMap { bucket, items in
            guard !items.isEmpty else { return nil }
            return HistoryTimelineSection(
                id: bucket.rawValue,
                title: bucket.title,
                symbolName: bucket.symbolName,
                entries: items
            )
        }
    }

    private static func groupByWeekday(_ entries: [HistoryEntry], now: Date) -> [HistoryTimelineSection] {
        let calendar = Calendar.current
        let dayKey: (Date) -> String = { date in
            let comps = calendar.dateComponents([.year, .day, .month], from: date)
            return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        var order: [String] = []
        var byKey: [String: [HistoryEntry]] = [:]
        var titleByKey: [String: String] = [:]
        for entry in entries {
            let key = dayKey(entry.lastVisitedAt)
            if byKey[key] == nil {
                order.append(key)
                titleByKey[key] = formatter.string(from: entry.lastVisitedAt)
            }
            byKey[key, default: []].append(entry)
        }
        return order.map { key in
            HistoryTimelineSection(
                id: key,
                title: titleByKey[key] ?? key,
                symbolName: "calendar",
                entries: byKey[key, default: []]
            )
        }
    }

    private static func groupByMonth(_ entries: [HistoryEntry]) -> [HistoryTimelineSection] {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        let calendar = Calendar.current
        let monthKey: (Date) -> String = { date in
            let comps = calendar.dateComponents([.year, .month], from: date)
            return "\(comps.year ?? 0)-\(comps.month ?? 0)"
        }
        var order: [String] = []
        var byKey: [String: [HistoryEntry]] = [:]
        var titleByKey: [String: String] = [:]
        for entry in entries {
            let key = monthKey(entry.lastVisitedAt)
            if byKey[key] == nil {
                order.append(key)
                titleByKey[key] = formatter.string(from: entry.lastVisitedAt)
            }
            byKey[key, default: []].append(entry)
        }
        return order.map { key in
            HistoryTimelineSection(
                id: key,
                title: titleByKey[key] ?? key,
                symbolName: "archivebox",
                entries: byKey[key, default: []]
            )
        }
    }

    enum TimeBucket: String, CaseIterable {
        case lateNight
        case morning
        case afternoon
        case evening

        var title: String {
            switch self {
            case .lateNight: "Late night"
            case .morning: "Morning"
            case .afternoon: "Afternoon"
            case .evening: "Evening"
            }
        }

        var symbolName: String {
            switch self {
            case .lateNight: "moon.stars"
            case .morning: "sunrise"
            case .afternoon: "sun.max"
            case .evening: "sunset"
            }
        }

        static func bucket(forHour hour: Int) -> TimeBucket {
            switch hour {
            case 0..<6: return .lateNight
            case 6..<12: return .morning
            case 12..<17: return .afternoon
            default: return .evening
            }
        }
    }
}

// MARK: - Hero subviews

private struct HistoryStatChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.textPrimary.opacity(0.7))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            Capsule()
                .fill(Palette.surface)
        }
        .overlay {
            Capsule()
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    private var label: String {
        if count == 1 { return "1 entry" }
        return "\(count.formatted(.number)) entries"
    }
}

private struct KindPill: View {
    let filter: HistoryKindFilter
    let count: Int
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: filter.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(filter.title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? Palette.bg.opacity(0.75) : Palette.textFaint)
            }
            .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(backgroundFill)
            }
            .overlay {
                Capsule()
                    .stroke(selected ? Color.clear : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }

    private var backgroundFill: Color {
        if selected { return Color.white }
        if isHovering { return Palette.surfaceHover }
        return Palette.surface
    }
}

// MARK: - Rail card

private struct GroupRailCard: View {
    let group: HistoryDateGroup
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconFill)
                    Image(systemName: group.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconForeground)
                }
                .frame(width: 24, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color.clear : Palette.stroke, lineWidth: 1)
                }

                Text(group.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)

                Spacer(minLength: 0)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? Palette.textSecondary : Palette.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3, height: 16)
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: isSelected)
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.07) }
        if isHovering { return Color.white.opacity(0.03) }
        return Color.clear
    }

    private var iconFill: Color {
        if isSelected { return Color.white.opacity(0.92) }
        return Palette.bgRaised
    }

    private var iconForeground: Color {
        if isSelected { return Palette.bg }
        return Palette.textSecondary
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
            HStack(alignment: .center, spacing: 14) {
                HistoryAvatar(entry: entry)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: subtitleDesign))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if entry.visitCount > 1 {
                    Text("\u{00D7}\(entry.visitCount)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule()
                                .fill(Palette.bgRaised)
                        }
                        .overlay {
                            Capsule()
                                .stroke(Palette.stroke, lineWidth: 1)
                        }
                }

                Text(timeLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.04) : Color.clear)
            }
            .overlay(alignment: .leading) {
                // Thin accent bar inside the row's leading padding —
                // overlay rather than HStack child so the row contents
                // don't shuffle when the bar fades in.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.7) : Color.clear)
                    .frame(width: 2, height: 22)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .contextMenu {
            if entry.isSearch {
                Button("Re-run search") { onOpen() }
                Button("Copy query") { copyToPasteboard(entry.title) }
            } else {
                Button("Open in new tab") { onOpenInBackground() }
                if let host = entry.host, let url = URL(string: "https://\(host)") {
                    Button("Visit site") { NSWorkspace.shared.open(url) }
                }
                Button("Copy link") { copyToPasteboard(entry.url.absoluteString) }
            }
            Divider()
            Button(entry.isSearch ? "Delete search" : "Delete entry", role: .destructive) { onDelete() }
            if !entry.isSearch, entry.host != nil {
                Button("Forget all visits to this site", role: .destructive) { onForgetSite() }
            }
        }
    }

    private var subtitle: String {
        if entry.isSearch {
            if let engine = entry.searchEngineLabel {
                return "Search \u{00B7} \(engine)"
            }
            return "Search"
        }
        return entry.url.absoluteString
    }

    private var subtitleDesign: Font.Design {
        entry.isSearch ? .default : .monospaced
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

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
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

/// Leading tile: favicon for visits, a search glyph for queries. The
/// search variant uses a white-on-graphite fill so it reads as a tag
/// even amid a long list of visit rows.
private struct HistoryAvatar: View {
    let entry: HistoryEntry

    var body: some View {
        if entry.isSearch {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.bgRaised)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
            }
        } else if let host = entry.host {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surface)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
                FaviconView(host: host)
                    .frame(width: 18, height: 18)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surface)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
                Image(systemName: "doc")
                    .font(.system(size: 12, weight: .semibold))
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
