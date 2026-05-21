import AppKit
import SwiftUI

struct BrowserShellView: View {
    @StateObject private var model = BrowserModel()
    @StateObject private var chatModel = ChatViewModel()
    @StateObject private var selectionWidget = TextSelectionWidgetModel()
    @StateObject private var smartReadModel = SmartReadModel()
    @StateObject private var readerModel = ReaderModeModel()
    @StateObject private var hoverPreview = HoverPreviewModel()
    @StateObject private var integrations = IntegrationsModel()
    @StateObject private var gmailAccount = GmailAccountStore.shared
    @StateObject private var gmailStore = GmailStore(account: GmailAccountStore.shared)

    @AppStorage(PreferenceKey.toggleChatShortcut) private var toggleChatShortcut = "command+j"
    @AppStorage(PreferenceKey.toggleTabsShortcut) private var toggleTabsShortcut = "command+b"
    @AppStorage(PreferenceKey.newTabShortcut) private var newTabShortcut = "command+t"
    @AppStorage(PreferenceKey.closeTabShortcut) private var closeTabShortcut = "command+w"
    @AppStorage(PreferenceKey.focusAddressShortcut) private var focusAddressShortcut = "command+l"
    @AppStorage(PreferenceKey.smartReadShortcut) private var smartReadShortcut = "shift+command+r"
    @AppStorage(PreferenceKey.readerModeShortcut) private var readerModeShortcut = "command+r"
    @AppStorage(PreferenceKey.pasteWithCitationShortcut) private var pasteWithCitationShortcut = "shift+command+v"
    @AppStorage(PreferenceKey.openDiscordShortcut) private var openDiscordShortcut = "command+d"
    @AppStorage(PreferenceKey.openHistoryShortcut) private var openHistoryShortcut = "command+y"
    @AppStorage(PreferenceKey.openIntegrationsShortcut) private var openIntegrationsShortcut = "shift+command+e"
    @AppStorage(PreferenceKey.migrationPromptCompleted) private var migrationPromptCompleted = false
    @AppStorage(PreferenceKey.historyImportBackfillCompleted) private var historyImportBackfillCompleted = false
    @AppStorage(PreferenceKey.hoverPreviewEnabled) private var hoverPreviewEnabled = true
    @AppStorage(PreferenceKey.hoverPreviewPrefetchBlocklist) private var hoverPreviewBlocklist = ""

    @State private var isPeekingRail = false
    @State private var peekDismissTask: Task<Void, Never>? = nil
    @State private var isShowingMigrationPrompt = false
    @State private var isClipboardPopoverPresented = false
    @State private var isShowingHistoryModal = false

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
                        smartReadModel: smartReadModel,
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
                            readHighlightsContent: { indices in
                                chatModel.collectAttachments(indices: indices)
                            },
                            smartReadContent: {
                                smartReadModel.summaryText()
                            },
                            openMailIntegration: {
                                withAnimation(Motion.springSnap) {
                                    integrations.open(.gmail)
                                }
                            },
                            searchMail: { query, mailbox, maxResults in
                                try await gmailStore.searchForTool(
                                    query: query,
                                    mailbox: mailbox,
                                    maxResults: maxResults
                                )
                            },
                            readMailThread: { identifier in
                                try await gmailStore.readThreadForTool(identifier: identifier)
                            },
                            draftMailReply: { identifier, body in
                                try await gmailStore.draftReplyForTool(identifier: identifier, body: body)
                            },
                            saveAndOpenArtifact: { title, html in
                                let url = try ArtifactStore.shared.save(title: title, html: html)
                                model.openArtifact(at: url)
                                return url
                            },
                            runWebControl: { task in
                                await model.runWebControl(task: task, sessionDirectory: chatModel.sessionDirectory)
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

            // Hover Preview key monitor — only intercepts Return / ⌘Return
            // while a peek session is visible. KeyboardShortcutHost ignores
            // naked keystrokes (no modifier), so this lives in its own host.
            HoverPreviewKeyMonitor(
                sessionVisible: hoverPreview.session != nil,
                onReturn: { performHoverAction(background: false, pinned: false) },
                onCommandReturn: { performHoverAction(background: true, pinned: false) }
            )
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)

            // Find bar Esc monitor — covers the case where the user has
            // clicked into the page after typing a query (text field has
            // lost focus, but the find bar is still open).
            FindBarEscapeMonitor(
                isActive: model.selectedTab.findController.isVisible,
                onEscape: { model.selectedTab.findController.hide() }
            )
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)

            // Hidden window chrome configurator (full-screen on green button)
            WindowFullScreenZoomConfigurator()
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            // Integrations overlay (Gmail, future Slack/Calendar/…).
            // Sits below the notification toasts so any incoming toast
            // still surfaces above it.
            if integrations.isPresented {
                IntegrationsOverlay(
                    model: integrations,
                    gmailAccount: gmailAccount,
                    gmailStore: gmailStore
                )
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Top layer: app-wide notification toasts
            NotificationOverlay()
                .ignoresSafeArea()
                .allowsHitTesting(true)
                .zIndex(2)
        }
        .background(Palette.bg)
        .onChange(of: model.selectedTabID) { _, _ in
            model.updateAddressFromSelectedTab()
            if readerModel.isPresented {
                readerModel.close()
            }
            hoverPreview.dismiss()
            installLinkHoverListener()
            // Smart Read state is pinned to the tab so it survives
            // hibernation. Pull the freshly-selected tab's saved state
            // into the shared model so the card reflects this tab.
            smartReadModel.bind(to: model.selectedTab)
        }
        .onChange(of: hoverPreviewEnabled) { _, newValue in
            for tab in model.tabs { tab.updateHoverPreviewEnabled(newValue) }
            if !newValue { hoverPreview.dismiss() }
        }
        .onChange(of: hoverPreviewBlocklist) { _, newValue in
            hoverPreview.prefetcher.updateBlocklist(newValue)
        }
        .onAppear {
            postWelcomeNotificationIfNeeded()
            installLinkHoverListener()
            hoverPreview.prefetcher.updateBlocklist(hoverPreviewBlocklist)
            for tab in model.tabs { tab.updateHoverPreviewEnabled(hoverPreviewEnabled) }
            smartReadModel.bind(to: model.selectedTab)
            backfillImportedHistoryIfNeeded()
            guard !migrationPromptCompleted else { return }
            isShowingMigrationPrompt = true
        }
        .onReceive(NotificationCenter.default.publisher(for: CitedClipboardPopoverModel.draftRequestedNotification)) { note in
            guard let clips = note.userInfo?[CitedClipboardPopoverModel.draftRequestedClipsKey] as? [CitedClip] else { return }
            handleDraftRequest(clips: clips)
        }
        .sheet(isPresented: $isShowingMigrationPrompt) {
            MigrationView(presentation: .firstRun) {
                migrationPromptCompleted = true
                isShowingMigrationPrompt = false
            }
            .frame(width: 740, height: 620)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isShowingHistoryModal) {
            HistoryModalView(
                onClose: { isShowingHistoryModal = false },
                onOpen: { url in
                    isShowingHistoryModal = false
                    model.addressDraft = url.absoluteString
                    model.navigateSelected(to: url.absoluteString)
                },
                onOpenInBackgroundTab: { url in
                    model.openInNewTab(url: url, background: true)
                },
                onOpenSearch: { query in
                    isShowingHistoryModal = false
                    model.addressDraft = query
                    model.navigateSelected(to: query)
                }
            )
            .frame(minWidth: 880, idealWidth: 1000, minHeight: 580, idealHeight: 680)
            .preferredColorScheme(.dark)
        }
        .animation(Motion.springSnap, value: model.isChatVisible)
        .animation(Motion.springSnap, value: model.isTabRailVisible)
        .animation(Motion.springSnap, value: integrations.isPresented)
    }

    // MARK: - Center column (toolbar + content)

    private var centerColumn: some View {
        VStack(spacing: 0) {
            BrowserToolbar(
                model: model,
                selectedTab: model.selectedTab,
                reservesTrafficLightGutter: !model.isTabRailVisible,
                readerActive: readerModel.isPresented,
                onSmartRead: triggerSmartRead,
                onReaderMode: triggerReaderMode,
                isClipboardPopoverPresented: $isClipboardPopoverPresented
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
                    BrowserTabContent(tab: model.selectedTab)
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
                            HoverPreviewOverlay(
                                model: hoverPreview,
                                actions: hoverPreviewActions
                            )
                        }
                        .overlay(alignment: .topTrailing) {
                            FindBarOverlay(controller: model.selectedTab.findController)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                                .stroke(Palette.stroke, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .padding(.horizontal, Metrics.webviewInset)
                        .padding(.bottom, Metrics.webviewInset)

                    if readerModel.isPresented {
                        ReaderModeView(
                            model: readerModel,
                            onOpenLink: { url in
                                readerModel.close()
                                model.addressDraft = url.absoluteString
                                model.navigateSelected(to: url.absoluteString)
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                    }
                }

                if let status = model.webControlStatus {
                    WebControlWorkingOverlay(status: status)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.springSnap, value: readerModel.isPresented)
            .animation(Motion.springSnap, value: model.webControlStatus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ask action (Summarize lives inside the overlay sub-view)

    /// Queues the highlight as a first-class attachment on the chat
    /// composer, opens the chat panel if it's hidden, and focuses the
    /// composer so the user can type their question on top of fresh
    /// context. Highlights are passed to the AI in a structured prompt
    /// block — see `ChatViewModel.attachHighlight` and
    /// `AIProviderClient.prompt(for:...)`.
    private func handleAsk(text: String) {
        chatModel.attachHighlight(text: text, pageContext: model.selectedContext)
        if !model.isChatVisible {
            withAnimation(Motion.springSnap) { model.toggleChat() }
        }
        DispatchQueue.main.async {
            chatModel.focusComposer()
        }
        model.selectedTab.clearSelectionInfo()
    }

    /// Hands off a set of clips from the cited clipboard popover to the
    /// chat sidebar's draft mode: opens the chat if it's hidden, queues
    /// the clips as attachments, and surfaces the preset chooser above
    /// the composer.
    private func handleDraftRequest(clips: [CitedClip]) {
        guard !clips.isEmpty else { return }
        if !model.isChatVisible {
            withAnimation(Motion.springSnap) { model.toggleChat() }
        }
        chatModel.beginDraftFromClips(clips)
    }

    /// Kicks off a Smart Read summary and opens the AI chat sidebar so the
    /// resulting card has somewhere to land. The card renders inside the chat
    /// panel above the message list (see `AIChatPanel.messageList`).
    private func triggerSmartRead() {
        guard model.selectedTab.isSmartReadEligible else { return }
        if !model.isChatVisible {
            withAnimation(Motion.springSnap) { model.toggleChat() }
        }
        withAnimation(Motion.springSnap) {
            smartReadModel.start(tab: model.selectedTab)
        }
    }

    /// Toggles Reader Mode for the current tab. Replaces the web view with a
    /// matte-white, serif-typeset article extracted from the page. Idempotent
    /// — invoking again while open closes Reader Mode.
    private func triggerReaderMode() {
        guard model.selectedTab.isSmartReadEligible else { return }
        withAnimation(Motion.springSnap) {
            readerModel.toggle(tab: model.selectedTab)
        }
    }

    // MARK: - Welcome notification

    /// Static guard so the welcome toast only fires once per app launch,
    /// even if `BrowserShellView` is reconstructed.
    private static var didPostWelcomeThisLaunch = false

    /// One-time pull of the existing migration-imported history rows into
    /// the SQLite ``HistoryStore``. Gated by a UserDefaults flag so the
    /// next launch is a no-op. Subsequent migrations run their own import
    /// directly via ``HistoryStore/importMigratedEntries``.
    ///
    /// Always touches ``HistoryStore/shared`` so the SQLite file is created
    /// at app start, not the first time someone records a visit — keeps the
    /// first navigation free of an unexpected file-system roundtrip.
    private func backfillImportedHistoryIfNeeded() {
        _ = HistoryStore.shared.count()
        guard !historyImportBackfillCompleted else { return }
        let imported = MigrationImportStore.importedHistory(limit: 5_000)
        if !imported.isEmpty {
            HistoryStore.shared.importMigratedEntries(imported)
        }
        historyImportBackfillCompleted = true
    }

    private func postWelcomeNotificationIfNeeded() {
        guard !Self.didPostWelcomeThisLaunch else { return }
        Self.didPostWelcomeThisLaunch = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            AppNotificationCenter.shared.post(
                title: "Welcome to TheBrowser",
                message: "Press \u{2318}J to chat with AI on any page. Tweak everything in Settings.",
                icon: "sparkles",
                kind: .info,
                duration: 6.5
            )
        }
    }

    // MARK: - Hover Preview wiring

    /// Subscribes the active tab's link-hover bridge to the shell-level
    /// preview model. Called on appear and whenever the selected tab
    /// changes; the previous tab's listener is cleared so we never get
    /// two hover overlays at once.
    private func installLinkHoverListener() {
        for tab in model.tabs where tab.id != model.selectedTabID {
            tab.setLinkHoverListener(nil)
        }
        let active = model.selectedTab
        active.setLinkHoverListener { [weak hoverPreview = hoverPreview] tab, info in
            guard let hoverPreview else { return }
            guard let url = info.url else { return }
            switch info.kind {
            case .peek:
                hoverPreview.peek(
                    url: url,
                    anchor: info.rect,
                    tab: tab,
                    fallbackTitle: info.title
                )
            case .prefetch:
                hoverPreview.prefetch(url: url)
            case .rect:
                hoverPreview.updateRect(info.rect, for: url)
            case .leave:
                hoverPreview.pointerLeftLink()
            }
        }
    }

    private var hoverPreviewActions: HoverPreviewActions {
        HoverPreviewActions(
            openInTab: { performHoverAction(background: false, pinned: false) },
            openInBackground: { performHoverAction(background: true, pinned: false) },
            pin: { performHoverAction(background: true, pinned: true) }
        )
    }

    private func performHoverAction(background: Bool, pinned: Bool) {
        guard let session = hoverPreview.session else { return }
        let url = session.url
        hoverPreview.dismiss()
        model.openInNewTab(url: url, background: background, pinned: pinned)
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

    /// Built imperatively (rather than from a `[Key: Value]` literal) because
    /// users can rebind any chord, so two preferences may legitimately end up
    /// holding the same string — a literal would fatal-error. Earlier rows in
    /// the list below take precedence when two preferences collide.
    private var shortcutBindings: [String: () -> Void] {
        var bindings: [String: () -> Void] = [:]
        let pairs: [(String, () -> Void)] = [
            (toggleChatShortcut, {
                let willBeVisible = !model.isChatVisible
                withAnimation(Motion.springSnap) { model.toggleChat() }
                if willBeVisible {
                    DispatchQueue.main.async {
                        chatModel.focusComposer()
                    }
                }
            }),
            (toggleTabsShortcut, { withAnimation(Motion.springSnap) { model.toggleTabs() } }),
            (newTabShortcut, { model.addTab() }),
            (closeTabShortcut, { model.closeSelected() }),
            (focusAddressShortcut, { model.focusAddress() }),
            (smartReadShortcut, triggerSmartRead),
            (readerModeShortcut, triggerReaderMode),
            (pasteWithCitationShortcut, { CitedClipboardCursorPanelController.shared.toggle() }),
            (openDiscordShortcut, { model.openOrFocusDiscord() }),
            (openHistoryShortcut, { isShowingHistoryModal.toggle() }),
            (openIntegrationsShortcut, { integrations.toggle() }),
            // Find in Page — fixed shortcuts, no Settings UI on purpose
            // since every browser ships these unchanged.
            ("command+f", { model.selectedTab.findController.show() }),
            ("command+g", { model.selectedTab.findController.next() }),
            ("shift+command+g", { model.selectedTab.findController.previous() })
        ]
        for (key, action) in pairs where bindings[key] == nil {
            bindings[key] = action
        }
        return bindings
    }
}

/// Renders the find bar overlay only when the active tab has it open.
/// Observes the controller directly so isVisible toggles trigger a
/// re-render — the BrowserTab itself doesn't re-publish on
/// findController changes. The selected-tab swap is handled at the
/// parent level (the .overlay closure re-evaluates whenever
/// `model.selectedTab` changes, picking up the new controller).
private struct FindBarOverlay: View {
    @ObservedObject var controller: FindController

    var body: some View {
        Group {
            if controller.isVisible {
                FindBarView(controller: controller)
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -8)),
                        removal: .opacity.combined(with: .offset(y: -4))
                    ))
            }
        }
        .animation(Motion.springSnap, value: controller.isVisible)
    }
}

private struct WebControlWorkingOverlay: View {
    var status: WebControlStatus
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            PixelCornerDissolve()
                .padding(.horizontal, Metrics.webviewInset)
                .padding(.bottom, Metrics.webviewInset)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                statusChip
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, Metrics.webviewInset)
            .padding(.bottom, Metrics.webviewInset)
        }
        .allowsHitTesting(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.white.opacity(pulse ? 0.95 : 0.40))
                .frame(width: 5, height: 5)

            Text("Agent is working")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            if !status.detail.isEmpty {
                Text("·")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                Text(status.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .id(status.detail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.80))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 16, x: 0, y: 8)
    }
}

/// Each of the four webview corners dissolves into a fine field of soft
/// round dots, coloured to match `Palette.bg` so the page looks like it's
/// breaking into the surrounding chrome. Per-pixel phase offsets let each
/// dot fade in (small→big) and out independently — a quiet, ethereal
/// shimmer rather than a hard twinkle.
private struct PixelCornerDissolve: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { gc, size in
                let cell: CGFloat = 6
                let maxRadius: CGFloat = 2.8
                let extent: CGFloat = 140
                let cycle: Double = 2.4
                let t = context.date.timeIntervalSinceReferenceDate
                let color = Palette.bg

                draw(gc, size: size, anchor: .topLeading,
                     cell: cell, maxRadius: maxRadius, extent: extent,
                     t: t, cycle: cycle, color: color, salt:  1.7)
                draw(gc, size: size, anchor: .topTrailing,
                     cell: cell, maxRadius: maxRadius, extent: extent,
                     t: t, cycle: cycle, color: color, salt: 13.1)
                draw(gc, size: size, anchor: .bottomLeading,
                     cell: cell, maxRadius: maxRadius, extent: extent,
                     t: t, cycle: cycle, color: color, salt: 29.9)
                draw(gc, size: size, anchor: .bottomTrailing,
                     cell: cell, maxRadius: maxRadius, extent: extent,
                     t: t, cycle: cycle, color: color, salt: 53.3)
            }
        }
    }

    private enum CornerAnchor { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func draw(
        _ gc: GraphicsContext,
        size: CGSize,
        anchor: CornerAnchor,
        cell: CGFloat,
        maxRadius: CGFloat,
        extent: CGFloat,
        t: Double,
        cycle: Double,
        color: Color,
        salt: Double
    ) {
        let count = Int(extent / cell)
        let countD = Double(count)

        for gx in 0..<count {
            for gy in 0..<count {
                let dx = Double(gx)
                let dy = Double(gy)
                let dist = sqrt(dx * dx + dy * dy) / countD
                if dist >= 1 { continue }

                let density = 1 - dist
                let densityCurve = density * density

                if noise(gx, gy, salt) > densityCurve { continue }

                let phaseOffset = noise(gx, gy, salt + 97)
                let phase = ((t / cycle) + phaseOffset).truncatingRemainder(dividingBy: 1.0)

                // Half the cycle invisible, half spent fading in then out.
                guard phase < 0.5 else { continue }
                let scale = sin(phase * 2 * .pi)

                let radius = maxRadius * CGFloat(densityCurve) * CGFloat(scale)
                if radius < 0.3 { continue }

                let fx = (CGFloat(gx) + 0.5) * cell
                let fy = (CGFloat(gy) + 0.5) * cell
                let cx: CGFloat
                let cy: CGFloat
                switch anchor {
                case .topLeading:
                    cx = fx;                cy = fy
                case .topTrailing:
                    cx = size.width - fx;   cy = fy
                case .bottomLeading:
                    cx = fx;                cy = size.height - fy
                case .bottomTrailing:
                    cx = size.width - fx;   cy = size.height - fy
                }

                let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                gc.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }

    private func noise(_ x: Int, _ y: Int, _ salt: Double) -> Double {
        let v = sin(Double(x) * 12.9898 + Double(y) * 78.233 + salt * 1.7) * 43758.5453
        return v - floor(v)
    }
}
