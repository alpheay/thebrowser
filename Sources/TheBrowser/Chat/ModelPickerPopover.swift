import AppKit
import SwiftUI

struct ModelPickerPopover: View {
    var onPicked: () -> Void = {}

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @AppStorage(PreferenceKey.aiFavoriteModels) private var favoritesRaw = ""

    @State private var search = ""
    @State private var highlightedID: String? = nil
    @FocusState private var searchFocused: Bool

    private let popoverWidth: CGFloat = 248

    var body: some View {
        VStack(spacing: 0) {
            searchField
            hairline
            modelList
        }
        .frame(width: popoverWidth)
        .frame(minHeight: 120, maxHeight: 420)
        .background(Palette.bg)
        .onAppear {
            highlightedID = currentSelectionRowID ?? flatVisibleRowIDs.first
        }
        .task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            searchFocused = true
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            TextField("Filter", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
                .onChange(of: search) { _, _ in
                    highlightedID = flatVisibleRowIDs.first
                }
                .onSubmit { commitHighlighted() }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 1)
    }

    // MARK: - List

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if !visibleFavorites.isEmpty {
                        section(rows: visibleFavorites, inFavorites: true)
                    }
                    ForEach(AIProviderKind.allCases) { provider in
                        let models = visibleModels(for: provider)
                        if !models.isEmpty {
                            section(rows: models, inFavorites: false)
                        }
                    }
                    if flatVisibleRowIDs.isEmpty {
                        emptyState
                            .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: highlightedID) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let id = highlightedID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func section(rows: [AIModelOption], inFavorites: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { model in
                row(for: model, inFavorites: inFavorites)
            }
        }
    }

    private func row(for model: AIModelOption, inFavorites: Bool) -> some View {
        let rowID = rowID(for: model, inFavorites: inFavorites)
        return ModelRow(
            model: model,
            isSelected: isCurrent(model),
            isFavorite: favoriteIDs.contains(model.id),
            isHighlighted: highlightedID == rowID,
            shortcut: inFavorites ? shortcutLabel(for: model) : nil,
            onPick: { pick(model) },
            onToggleFavorite: { toggleFavorite(model) },
            onHover: { hovering in
                if hovering { highlightedID = rowID }
            }
        )
        .id(rowID)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        Text("No matches")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.textMuted)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Derived state

    private var favoriteIDs: [String] {
        favoritesRaw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var favoriteModels: [AIModelOption] {
        favoriteIDs.compactMap(AIModelOption.find(id:))
    }

    private var visibleFavorites: [AIModelOption] {
        applySearch(favoriteModels)
    }

    private func visibleModels(for provider: AIProviderKind) -> [AIModelOption] {
        applySearch(provider.availableModels)
    }

    private func applySearch(_ pool: [AIModelOption]) -> [AIModelOption] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return pool }
        return pool.filter {
            $0.displayName.lowercased().contains(query)
                || $0.modelID.lowercased().contains(query)
                || $0.provider.displayName.lowercased().contains(query)
        }
    }

    /// Flat ordering used by arrow-key navigation — matches the on-screen
    /// reading order so highlight moves predictably.
    private var flatVisibleRowIDs: [String] {
        var ids: [String] = []
        for model in visibleFavorites {
            ids.append(rowID(for: model, inFavorites: true))
        }
        for provider in AIProviderKind.allCases {
            for model in visibleModels(for: provider) {
                ids.append(rowID(for: model, inFavorites: false))
            }
        }
        return ids
    }

    private func rowID(for model: AIModelOption, inFavorites: Bool) -> String {
        inFavorites ? "fav:\(model.id)" : model.id
    }

    private var currentSelectionRowID: String? {
        guard let model = AIModelOption.find(id: "\(aiProvider):\(aiModel)") else { return nil }
        if favoriteIDs.contains(model.id) {
            return rowID(for: model, inFavorites: true)
        }
        return rowID(for: model, inFavorites: false)
    }

    private func isCurrent(_ model: AIModelOption) -> Bool {
        model.provider.rawValue == aiProvider && model.modelID == aiModel
    }

    private func shortcutLabel(for model: AIModelOption) -> String? {
        guard let idx = favoriteIDs.firstIndex(of: model.id), idx < 9 else { return nil }
        return "⌘\(idx + 1)"
    }

    // MARK: - Actions

    private func pick(_ model: AIModelOption) {
        aiProvider = model.provider.rawValue
        aiModel = model.modelID
        onPicked()
    }

    private func toggleFavorite(_ model: AIModelOption) {
        var ids = favoriteIDs
        if let idx = ids.firstIndex(of: model.id) {
            ids.remove(at: idx)
        } else {
            ids.append(model.id)
        }
        favoritesRaw = ids.joined(separator: ",")
    }

    private func moveHighlight(by delta: Int) {
        let ids = flatVisibleRowIDs
        guard !ids.isEmpty else { return }
        let currentIdx = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        let nextIdx = min(max(currentIdx + delta, 0), ids.count - 1)
        highlightedID = ids[nextIdx]
    }

    private func commitHighlighted() {
        guard let rowID = highlightedID else { return }
        let modelID = rowID.hasPrefix("fav:") ? String(rowID.dropFirst(4)) : rowID
        if let model = AIModelOption.find(id: modelID) {
            pick(model)
        }
    }
}

// MARK: - Row

private struct ModelRow: View {
    var model: AIModelOption
    var isSelected: Bool
    var isFavorite: Bool
    var isHighlighted: Bool
    var shortcut: String?
    var onPick: () -> Void
    var onToggleFavorite: () -> Void
    var onHover: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(model.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? Palette.text : Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textMuted)
                    .monospacedDigit()
            }

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isFavorite ? Palette.textSecondary : Palette.textMuted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFavorite || isHovering || isHighlighted ? 1 : 0)
            .help(isFavorite ? "Unfavorite" : "Favorite")

            Circle()
                .fill(Palette.text)
                .frame(width: 5, height: 5)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 8, alignment: .center)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover {
            isHovering = $0
            onHover($0)
        }
        .onTapGesture { onPick() }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isHighlighted)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.06) }
        if isHighlighted || isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }
}
