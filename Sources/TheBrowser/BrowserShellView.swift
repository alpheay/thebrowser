import SwiftUI

struct BrowserShellView: View {
    @StateObject private var model = BrowserModel()
    @StateObject private var chatModel = ChatViewModel()

    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"

    var body: some View {
        ZStack {
            AmbientBackground()

            HStack(spacing: 0) {
                if model.isTabRailVisible {
                    TabRailView(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    BrowserToolbar(model: model)

                    ZStack {
                        if model.selectedTab.isHome {
                            HomePageView { destination in
                                model.addressDraft = destination
                                model.navigateSelected(to: destination)
                            }
                        } else {
                            BrowserWebView(tab: model.selectedTab)
                                .id(model.selectedTab.id)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.isChatVisible {
                    AIChatPanel(
                        viewModel: chatModel,
                        context: model.selectedContext,
                        onClose: { withAnimation(.snappy) { model.toggleChat() } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Palette.ink)
        .overlay(alignment: .bottomLeading) {
            KeyboardShortcutHost(
                toggleChatShortcut: toggleChatShortcut,
                toggleTabsShortcut: toggleTabsShortcut,
                onToggleChat: { withAnimation(.snappy) { model.toggleChat() } },
                onToggleTabs: { withAnimation(.snappy) { model.toggleTabs() } }
            )
            .frame(width: 1, height: 1)
        }
        .onChange(of: model.selectedTabID) { _, _ in
            model.updateAddressFromSelectedTab()
        }
        .animation(.snappy(duration: 0.24), value: model.isChatVisible)
        .animation(.snappy(duration: 0.24), value: model.isTabRailVisible)
    }
}

private struct AmbientBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(
                    x: size.width * (0.5 + 0.08 * cos(time / 8)),
                    y: size.height * (0.44 + 0.08 * sin(time / 10))
                )

                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(Palette.ink))

                let bands: [(Color, CGFloat, CGFloat)] = [
                    (Palette.coral.opacity(0.44), 0.16, 0.14),
                    (Palette.saffron.opacity(0.33), -0.21, 0.10),
                    (Palette.cyan.opacity(0.28), 0.24, -0.18),
                    (Palette.plum.opacity(0.24), -0.12, -0.22)
                ]

                for (color, xOffset, yOffset) in bands {
                    let bandRect = CGRect(
                        x: center.x + size.width * xOffset - size.width * 0.32,
                        y: center.y + size.height * yOffset - size.height * 0.18,
                        width: size.width * 0.64,
                        height: size.height * 0.36
                    )
                    let path = Path(roundedRect: bandRect, cornerRadius: min(size.width, size.height) * 0.18)
                    context.addFilter(.blur(radius: 80))
                    context.fill(path, with: .color(color))
                }
            }
        }
        .ignoresSafeArea()
    }
}
