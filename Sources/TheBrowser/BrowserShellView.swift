import AppKit
import SwiftUI

struct BrowserShellView: View {
    @StateObject private var model = BrowserModel()
    @StateObject private var chatModel = ChatViewModel()

    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"
    @AppStorage(PreferenceKey.newTabShortcut) private var newTabShortcut = "command+t"
    @AppStorage(PreferenceKey.closeTabShortcut) private var closeTabShortcut = "command+w"
    @AppStorage(PreferenceKey.focusAddressShortcut) private var focusAddressShortcut = "command+l"

    @State private var isPeekingRail = false
    @State private var peekDismissTask: Task<Void, Never>? = nil

    private var railOverlayVisible: Bool {
        model.isTabRailVisible || isPeekingRail
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Layer 0: window plate
            Palette.bg
                .ignoresSafeArea()

            // Layer 1: main HStack — rail | center | chat, all full height
            HStack(spacing: 0) {
                if model.isTabRailVisible {
                    TabRailView(model: model)
                }

                centerColumn

                if model.isChatVisible {
                    AIChatPanel(
                        viewModel: chatModel,
                        context: model.selectedContext,
                        onClose: {
                            withAnimation(Motion.springSnap) { model.toggleChat() }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()

            // Layer 2: hover-peek rail overlay (only when rail is hidden)
            if !model.isTabRailVisible && isPeekingRail {
                HStack(spacing: 0) {
                    TabRailView(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .onHover { hovering in
                            if hovering {
                                cancelPeekDismiss()
                            } else {
                                schedulePeekDismiss()
                            }
                        }
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
            }

            // Layer 3: invisible hover strip for peek detection (only when rail hidden)
            if !model.isTabRailVisible {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                cancelPeekDismiss()
                                if !isPeekingRail {
                                    withAnimation(Motion.springSnap) {
                                        isPeekingRail = true
                                    }
                                }
                            case .ended:
                                schedulePeekDismiss()
                            }
                        }
                    Spacer()
                }
                .ignoresSafeArea()
            }

            // Hidden keyboard shortcut host
            KeyboardShortcutHost(bindings: shortcutBindings)
                .frame(width: 0, height: 0)
                .opacity(0)

            // Hidden window chrome configurator (full-screen on green button)
            WindowFullScreenZoomConfigurator()
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .background(Palette.bg)
        .onChange(of: model.selectedTabID) { _, _ in
            model.updateAddressFromSelectedTab()
        }
        .animation(Motion.springSnap, value: model.isChatVisible)
        .animation(Motion.springSnap, value: model.isTabRailVisible)
    }

    // MARK: - Center column (toolbar + content)

    private var centerColumn: some View {
        VStack(spacing: 0) {
            BrowserToolbar(
                model: model,
                selectedTab: model.selectedTab,
                reservesTrafficLightGutter: !model.isTabRailVisible
            )

            ZStack {
                if model.selectedTab.isHome {
                    HomePageView { destination in
                        model.addressDraft = destination
                        model.navigateSelected(to: destination)
                    }
                } else {
                    BrowserWebView(tab: model.selectedTab)
                        .id(model.selectedTab.id)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                                .stroke(Palette.stroke, lineWidth: 1)
                        }
                        .padding(.horizontal, Metrics.webviewInset)
                        .padding(.bottom, Metrics.webviewInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hover-peek timing

    private func schedulePeekDismiss() {
        peekDismissTask?.cancel()
        peekDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 240_000_000)
            if !Task.isCancelled {
                withAnimation(Motion.springSnap) {
                    isPeekingRail = false
                }
            }
        }
    }

    private func cancelPeekDismiss() {
        peekDismissTask?.cancel()
        peekDismissTask = nil
    }

    // MARK: - Shortcut bindings

    private var shortcutBindings: [String: () -> Void] {
        [
            toggleChatShortcut: {
                withAnimation(Motion.springSnap) { model.toggleChat() }
            },
            toggleTabsShortcut: {
                withAnimation(Motion.springSnap) { model.toggleTabs() }
            },
            newTabShortcut: {
                model.addTab()
            },
            closeTabShortcut: {
                model.closeSelected()
            },
            focusAddressShortcut: {
                model.focusAddress()
            }
        ]
    }
}
