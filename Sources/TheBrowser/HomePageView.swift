import SwiftUI

struct HomePageView: View {
    @State private var query = ""
    @FocusState private var pillFocused: Bool

    var onNavigate: (String) -> Void

    var body: some View {
        ZStack {
            Palette.bg
                .contentShape(Rectangle())
                .onTapGesture {
                    pillFocused = false
                }

            VStack(spacing: 36) {
                Spacer()

                Text("your browser")
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(Palette.textPrimary.opacity(0.92))

                searchPill
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 36)

                shortcutRow

                Spacer()
                Spacer()
            }
        }
    }

    private var searchPill: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Palette.textMuted)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search, ask, or type a URL")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .focused($pillFocused)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textPrimary)
                    .onSubmit { submit() }
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(pillFocused ? Color.white.opacity(0.18) : Palette.stroke, lineWidth: 1)
                .animation(.easeOut(duration: 0.16), value: pillFocused)
        }
    }

    private var shortcutRow: some View {
        HStack(spacing: 20) {
            ForEach(shortcuts) { shortcut in
                ShortcutLink(title: shortcut.title) {
                    onNavigate(shortcut.destination)
                }
            }
        }
        .padding(.horizontal, 36)
    }

    private var shortcuts: [HomeShortcut] {
        let imported = MigrationImportStore.importedBookmarks(limit: 4)
        if !imported.isEmpty {
            return imported.map { bookmark in
                HomeShortcut(title: bookmark.title, destination: bookmark.url)
            }
        }

        return [
            HomeShortcut(title: "Research", destination: "https://www.perplexity.ai"),
            HomeShortcut(title: "Codex docs", destination: "https://developers.openai.com/codex"),
            HomeShortcut(title: "Hacker News", destination: "https://news.ycombinator.com"),
            HomeShortcut(title: "GitHub", destination: "https://github.com")
        ]
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onNavigate(trimmed)
        query = ""
    }
}

private struct HomeShortcut: Identifiable {
    let id = UUID()
    var title: String
    var destination: String
}

private struct ShortcutLink: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 120)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
