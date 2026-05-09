import SwiftUI

struct TabRailView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 14) {
            brand

            Button {
                model.addTab()
            } label: {
                Label("New", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .help("New tab")

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.tabs) { tab in
                        TabRow(
                            tab: tab,
                            selected: tab.id == model.selectedTabID,
                            onSelect: { model.select(tab) },
                            onClose: { model.close(tab) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 9) {
                StatusChip(color: Palette.mint, text: "Codex CLI")
                StatusChip(color: Palette.cyan, text: "\(model.tabs.count) \(model.tabs.count == 1 ? "space" : "spaces")")
            }
        }
        .padding(12)
        .frame(width: 244)
        .background(Palette.graphite.opacity(0.86))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.saffron, Palette.coral, Palette.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("The Browser")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.pearl)
                Text("AI-native")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .textCase(.uppercase)
                    .tracking(1)
            }

            Spacer()
        }
    }
}

private struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tabColor)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: tab.isHome ? "sparkle" : "globe")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selected ? Palette.ink : Palette.pearl)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Palette.ink : Palette.pearl)
                        .lineLimit(1)

                    Text(tab.isHome ? "Start here" : tab.displayAddress)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Palette.ink.opacity(0.62) : Palette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Palette.ink.opacity(0.72) : Palette.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .help("Close tab")
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.pearl : Color.white.opacity(0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.white.opacity(0.36) : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var tabColor: Color {
        if selected {
            return Palette.saffron
        }

        return tab.isHome ? Palette.plum.opacity(0.45) : Palette.cyan.opacity(0.35)
    }
}

private struct StatusChip: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassPanel()
    }
}
