import SwiftUI

struct ModelPickerPopover: View {
    var onPicked: () -> Void = {}

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue
    @AppStorage(PreferenceKey.aiModel) private var aiModel = ""
    @AppStorage(PreferenceKey.aiFavoriteModels) private var favoritesRaw = ""

    @State private var search = ""
    @State private var filter: PickerFilter = .favorites
    @FocusState private var searchFocused: Bool

    enum PickerFilter: Hashable {
        case favorites
        case provider(AIProviderKind)
    }

    var body: some View {
        HStack(spacing: 0) {
            providerRail
            modelArea
        }
        .frame(width: 380, height: 360)
        .background(Palette.bg)
        .task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            searchFocused = true
        }
    }

    // MARK: - Provider rail

    private var providerRail: some View {
        VStack(spacing: 4) {
            railButton(
                isSelected: filter == .favorites,
                systemName: filter == .favorites ? "star.fill" : "star",
                accessibilityLabel: "Favorites"
            ) {
                filter = .favorites
            }

            ForEach(AIProviderKind.allCases) { provider in
                railButton(
                    isSelected: filter == .provider(provider),
                    systemName: provider.symbolName,
                    accessibilityLabel: provider.displayName
                ) {
                    filter = .provider(provider)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 50)
        .frame(maxHeight: .infinity)
        .background(Palette.bgSunken)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private func railButton(
        isSelected: Bool,
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Palette.text : Palette.textSecondary)
                .frame(width: 38, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Palette.surfaceActive : Color.clear)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Palette.strokeStrong, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Model area

    private var modelArea: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .background(Palette.stroke)
            modelList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            TextField("Search models...", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .padding(10)
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filteredModels.isEmpty {
                    emptyState
                }
                ForEach(filteredModels) { model in
                    ModelPickerRow(
                        model: model,
                        isSelected: model.provider.rawValue == aiProvider && model.modelID == aiModel,
                        isFavorite: favoriteIDs.contains(model.id),
                        shortcut: shortcutLabel(for: model),
                        onPick: {
                            aiProvider = model.provider.rawValue
                            aiModel = model.modelID
                            onPicked()
                        },
                        onToggleFavorite: {
                            toggleFavorite(model)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: filter == .favorites ? "star" : "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text(emptyTitle)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            if filter == .favorites {
                Text("Star a model to pin it here.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var emptyTitle: String {
        switch filter {
        case .favorites:
            return search.isEmpty ? "No favorites yet" : "No matching favorites"
        case .provider:
            return "No matches"
        }
    }

    // MARK: - Computed

    private var favoriteIDs: [String] {
        favoritesRaw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var filteredModels: [AIModelOption] {
        let pool: [AIModelOption]
        switch filter {
        case .favorites:
            pool = favoriteIDs.compactMap(AIModelOption.find(id:))
        case .provider(let provider):
            pool = provider.availableModels
        }

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return pool }
        return pool.filter {
            $0.displayName.lowercased().contains(query)
                || $0.modelID.lowercased().contains(query)
                || $0.provider.displayName.lowercased().contains(query)
        }
    }

    private func shortcutLabel(for model: AIModelOption) -> String? {
        guard filter == .favorites,
              let idx = favoriteIDs.firstIndex(of: model.id),
              idx < 9
        else { return nil }
        return "⌘\(idx + 1)"
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
}

private struct ModelPickerRow: View {
    var model: AIModelOption
    var isSelected: Bool
    var isFavorite: Bool
    var shortcut: String?
    var onPick: () -> Void
    var onToggleFavorite: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFavorite ? Palette.text : Palette.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unfavorite" : "Favorite")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: model.provider.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                    Text(model.provider.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Palette.textMuted)
            }

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.text)
            }

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            onPick()
        }
    }

    private var rowFill: Color {
        if isSelected { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }
}
