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

    private let popoverWidth: CGFloat = 308

    var body: some View {
        VStack(spacing: 0) {
            searchField
            divider
            modelList
        }
        .frame(width: popoverWidth)
        .frame(minHeight: 240, maxHeight: 460)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)

            TextField("Search models", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(height: 1)
            .opacity(0.6)
    }

    // MARK: - List

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !visibleFavorites.isEmpty {
                        favoritesSection
                    }
                    ForEach(AIProviderKind.allCases) { provider in
                        let models = visibleModels(for: provider)
                        if !models.isEmpty {
                            providerSection(provider, models: models)
                        }
                    }
                    if flatVisibleRowIDs.isEmpty {
                        emptyState
                            .padding(.vertical, 32)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlightedID) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .task {
                // Defer initial scroll until after layout so the focused row
                // lands in view on first open.
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let id = highlightedID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(icon: "star.fill", title: "Favorites")
            ForEach(visibleFavorites) { model in
                row(for: model, inFavorites: true)
            }
        }
    }

    private func providerSection(_ provider: AIProviderKind, models: [AIModelOption]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(provider: provider)
            ForEach(models) { model in
                row(for: model, inFavorites: false)
            }
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func sectionHeader(provider: AIProviderKind) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 10)
                .foregroundStyle(Palette.textMuted)
            Text(provider.displayName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
        .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text("No matches")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            Text("Try a different search.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
        }
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

    /// Stable order of every row id currently rendered. Drives arrow-key
    /// navigation so highlight moves match what the user actually sees.
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 14)
                    .transition(.scale.combined(with: .opacity))
            }

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFavorite ? Palette.textPrimary : Palette.textMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFavorite || isHovering || isHighlighted ? 1 : 0)
            .help(isFavorite ? "Unfavorite" : "Favorite")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        if isSelected { return Palette.surfaceActive }
        if isHighlighted || isHovering { return Palette.surfaceHover }
        return Color.clear
    }
}
