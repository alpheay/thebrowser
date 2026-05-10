import SwiftUI

struct TabRailView: View {
    @ObservedObject var model: BrowserModel
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        TabRow(
                            tab: tab,
                            selected: tab.id == model.selectedTabID,
                            namespace: selectionNamespace,
                            onSelect: { model.select(tab) },
                            onClose: { model.close(tab) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
        .hairline(.trailing)
    }

    private var header: some View {
        Button {
            model.addTab()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New tab")
                    .font(Typography.body)
                Spacer()
                Text("⌘T")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
            HStack(spacing: 8) {
                KeycapHint(text: "⌘B")
                Text("hide")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textFaint)
                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textFaint)
                KeycapHint(text: "⌘J")
                Text("chat")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
    }
}

private struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textMuted)
    }
}

private struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool
    var namespace: Namespace.ID
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Selection indicator slot
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Palette.accent)
                        .frame(width: 3, height: 16)
                        .matchedGeometryEffect(id: "selectionBar", in: namespace)
                }
            }
            .frame(width: 3)

            // Favicon / loading
            Group {
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else if let host = tab.url?.host(percentEncoded: false), !tab.isHome {
                    FaviconView(host: host)
                } else {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .frame(width: 16, height: 16)

            Text(tab.displayTitle)
                .font(Typography.body)
                .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
        .animation(Motion.springSoft, value: selected)
    }

    private var rowFill: Color {
        if selected { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }
}
