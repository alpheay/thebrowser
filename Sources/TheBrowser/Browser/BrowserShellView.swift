import AppKit
import SwiftUI

struct BrowserShellView: View {
    @StateObject private var model = BrowserModel()
    @StateObject private var chatModel = ChatViewModel()
    @StateObject private var selectionWidget = TextSelectionWidgetModel()
    @StateObject private var smartReadModel = SmartReadModel()

    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"
    @AppStorage(PreferenceKey.newTabShortcut) private var newTabShortcut = "command+t"
    @AppStorage(PreferenceKey.closeTabShortcut) private var closeTabShortcut = "command+w"
    @AppStorage(PreferenceKey.focusAddressShortcut) private var focusAddressShortcut = "command+l"
    @AppStorage(PreferenceKey.smartReadShortcut) private var smartReadShortcut = "command+shift+r"
    @AppStorage(PreferenceKey.migrationPromptCompleted) private var migrationPromptCompleted = false

    @State private var isPeekingRail = false
    @State private var peekDismissTask: Task<Void, Never>? = nil
    @State private var isShowingMigrationPrompt = false

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
                        tabs: model.tabsManifest(),
                        nativeTools: NativeBrowserToolExecutor(
                            openURL: { url in
                                model.addressDraft = url.absoluteString
                                model.navigateSelected(to: url.absoluteString)
                            },
                            readTabsContent: { indices in
                                await model.collectTabsContent(indices: indices)
                            },
                            saveAndOpenArtifact: { title, html in
                                let url = try ArtifactStore.shared.save(title: title, html: html)
                                model.openArtifact(at: url)
                                return url
                            }
                        ),
                        onOpenArtifact: { url in
                            model.openOrFocusArtifact(at: url)
                        },
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
                    .ignoresSafeArea()
            }

            // Hidden keyboard shortcut host
            KeyboardShortcutHost(bindings: shortcutBindings)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            // Hidden window chrome configurator (full-screen on green button)
            WindowFullScreenZoomConfigurator()
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            SmartReadOverlay(model: smartReadModel)
        }
        .background(Palette.bg)
        .onChange(of: model.selectedTabID) { _, _ in
            model.updateAddressFromSelectedTab()
        }
        .onAppear {
            guard !migrationPromptCompleted else { return }
            isShowingMigrationPrompt = true
        }
        .sheet(isPresented: $isShowingMigrationPrompt) {
            MigrationView(presentation: .firstRun) {
                migrationPromptCompleted = true
                isShowingMigrationPrompt = false
            }
            .frame(width: 740, height: 620)
            .preferredColorScheme(.dark)
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
                reservesTrafficLightGutter: !model.isTabRailVisible,
                onSmartRead: {
                    smartReadModel.start(tab: model.selectedTab)
                }
            )

            ZStack {
                if model.selectedTab.isHome {
                    HomePageView { destination in
                        model.addressDraft = destination
                        model.navigateSelected(to: destination)
                    }
                } else if let searchPage = model.selectedTab.searchPage {
                    SearchResultsView(
                        searchPage: searchPage,
                        reloadToken: model.selectedTab.searchReloadToken,
                        onOpen: { url in
                            model.addressDraft = url.absoluteString
                            model.navigateSelected(to: url.absoluteString)
                        }
                    )
                } else {
                    BrowserWebView(tab: model.selectedTab)
                        .id(model.selectedTab.id)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous))
                        .overlay {
                            TextSelectionOverlay(
                                tab: model.selectedTab,
                                widgetModel: selectionWidget,
                                pageContext: model.selectedContext,
                                onAsk: { text in handleAsk(text: text) }
                            )
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                                .stroke(Palette.stroke, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .padding(.horizontal, Metrics.webviewInset)
                        .padding(.bottom, Metrics.webviewInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ask action (Summarize lives inside the overlay sub-view)

    private func handleAsk(text: String) {
        let quoted = quotedDraft(for: text)
        if !model.isChatVisible {
            withAnimation(Motion.springSnap) { model.toggleChat() }
        }
        chatModel.draft = quoted
        DispatchQueue.main.async {
            chatModel.focusComposer()
        }
        model.selectedTab.clearSelectionInfo()
    }

    /// Builds the pre-filled chat draft: each line of the highlight is
    /// rendered as a Markdown blockquote, followed by a blank line where the
    /// user's actual question goes. Long passages are truncated with an
    /// ellipsis so the composer stays usable.
    private func quotedDraft(for text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let capped: String = {
            if normalized.count > 1200 {
                return String(normalized.prefix(1200)) + "…"
            }
            return normalized
        }()
        let quoted = capped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return quoted + "\n\n"
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
                let willBeVisible = !model.isChatVisible
                withAnimation(Motion.springSnap) { model.toggleChat() }
                if willBeVisible {
                    DispatchQueue.main.async {
                        chatModel.focusComposer()
                    }
                }
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
            },
            smartReadShortcut: {
                smartReadModel.start(tab: model.selectedTab)
            }
        ]
    }
}
