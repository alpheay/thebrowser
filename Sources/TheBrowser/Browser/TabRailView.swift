import SwiftUI

struct TabRailView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            // Reserve space for traffic lights at the top
            Color.clear
                .frame(height: Metrics.railTopPadding)

            NewTabButton {
                withAnimation(Motion.springSoft) {
                    model.addTab()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            sectionLabel
                .padding(.horizontal, 18)
                .padding(.bottom, 4)

            tabList

            footer
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
    }

    // MARK: - Section label

    private var sectionLabel: some View {
        HStack(spacing: 8) {
            Text("Tabs")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textFaint)

            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)
                .frame(maxWidth: .infinity)

            Text("\(model.tabs.count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
                .contentTransition(.numericText())
                .animation(Motion.springSnap, value: model.tabs.count)
        }
    }

    // MARK: - Tab list

    /// Pinned tabs always lead, preserving original insertion order within
    /// each group. Mirrors how Safari/Chrome stack their pinned strip.
    private var orderedTabs: [BrowserTab] {
        let pinned = model.tabs.filter { $0.isPinned }
        let rest = model.tabs.filter { !$0.isPinned }
        return pinned + rest
    }

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(orderedTabs) { tab in
                    TabRow(
                        tab: tab,
                        selected: tab.id == model.selectedTabID,
                        onSelect: {
                            withAnimation(Motion.springSoft) {
                                model.select(tab)
                            }
                        },
                        onClose: {
                            withAnimation(Motion.springSoft) {
                                model.close(tab)
                            }
                        }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -4)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                        )
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 8)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 16)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 7) {
            KeycapHint(text: "⌘B")
            Text("tabs")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            Circle()
                .fill(Palette.textFaint.opacity(0.6))
                .frame(width: 2, height: 2)
                .padding(.horizontal, 1)

            KeycapHint(text: "⌘J")
            Text("chat")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Palette.bg.opacity(0), Palette.bg],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 16)
            .offset(y: -16)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - New tab button

private struct NewTabButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            NewTabButtonLabel(isHovering: isHovering)
        }
        .buttonStyle(NewTabButtonStyle())
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct NewTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(Motion.microTap, value: configuration.isPressed)
            .environment(\.isPressed, configuration.isPressed)
    }
}

private struct IsPressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private extension EnvironmentValues {
    var isPressed: Bool {
        get { self[IsPressedKey.self] }
        set { self[IsPressedKey.self] = newValue }
    }
}

private struct NewTabButtonLabel: View {
    var isHovering: Bool
    @Environment(\.isPressed) private var isPressed

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(isPressed ? 90 : 0))
                .animation(Motion.springSnap, value: isPressed)

            Text("New tab")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 4)

            KeycapHint(text: "⌘T")
                .opacity(isHovering ? 1.0 : 0.55)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.surfaceHover : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Keycap

private struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Tab row

private struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        HStack(spacing: 10) {
            TabIcon(tab: tab, selected: selected)
                .frame(width: 16, height: 16)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                    .rotationEffect(.degrees(45))
            }

            Spacer(minLength: 4)

            CloseButton(
                isHovering: isCloseHovering,
                rowHovering: isHovering,
                action: onClose
            )
            .onHover { isCloseHovering = $0 }
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
        .animation(Motion.springSoft, value: selected)
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var rowFill: Color {
        if selected { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }
}

// MARK: - Tab icon

private struct TabIcon: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool

    var body: some View {
        Group {
            if tab.isLoading {
                LoadingPulse(selected: selected)
            } else if let host = tab.url?.host(percentEncoded: false), !tab.isHome {
                FaviconView(host: host)
            } else if tab.isHome {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textMuted)
            } else if tab.isArtifact {
                ArtifactMark()
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textMuted)
            } else {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Close button

private struct CloseButton: View {
    var isHovering: Bool
    var rowHovering: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovering ? Palette.surfaceActive : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(rowHovering ? 1 : 0)
        .scaleEffect(rowHovering ? 1.0 : 0.85)
        .animation(Motion.hoverFade, value: rowHovering)
        .animation(Motion.microTap, value: isHovering)
    }
}

// MARK: - Loading indicator

private struct LoadingPulse: View {
    var selected: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                selected ? Palette.textPrimary : Palette.textSecondary,
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(phase * 360))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
