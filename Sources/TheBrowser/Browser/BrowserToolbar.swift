import SwiftUI

struct BrowserToolbar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var selectedTab: BrowserTab
    var reservesTrafficLightGutter: Bool
    var readerActive: Bool = false
    var onSmartRead: () -> Void = {}
    var onReaderMode: () -> Void = {}
    @Binding var isClipboardPopoverPresented: Bool

    @AppStorage(PreferenceKey.toolbarShowBack) private var showBack = true
    @AppStorage(PreferenceKey.toolbarShowForward) private var showForward = true
    @AppStorage(PreferenceKey.toolbarShowReload) private var showReload = true
    @AppStorage(PreferenceKey.toolbarShowReaderMode) private var showReaderMode = true
    @AppStorage(PreferenceKey.toolbarShowSmartRead) private var showSmartRead = true
    @AppStorage(PreferenceKey.toolbarShowClipboard) private var showClipboard = true
    @AppStorage(PreferenceKey.toolbarShowTabRailToggle) private var showTabRailToggle = true
    @AppStorage(PreferenceKey.toolbarShowChatToggle) private var showChatToggle = true

    @FocusState private var addressFocused: Bool
    @State private var submitPulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if reservesTrafficLightGutter {
                    Color.clear
                        .frame(width: Metrics.trafficLightGutter, height: 28)
                }

                navCluster

                addressBar
                    .padding(.horizontal, 10)

                rightCluster
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.toolbarHeight)

            // Loading hairline
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 1.5)
                if selectedTab.isLoading {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: proxy.size.width * max(0.04, selectedTab.estimatedProgress), height: 1.5)
                            .animation(.easeOut(duration: 0.3), value: selectedTab.estimatedProgress)
                    }
                    .frame(height: 1.5)
                    .transition(.opacity)
                }
            }
            .frame(height: 1.5)
        }
        .background(Palette.bg)
    }

    private var navCluster: some View {
        HStack(spacing: 4) {
            if showBack {
                Button { selectedTab.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Back")
            }

            if showForward {
                Button { selectedTab.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Forward")
            }

            if showReload {
                Button {
                    if selectedTab.isLoading {
                        selectedTab.stopLoading()
                    } else {
                        selectedTab.reload()
                    }
                } label: {
                    Image(systemName: selectedTab.isLoading ? "xmark" : "arrow.clockwise")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help(selectedTab.isLoading ? "Stop" : "Reload")
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            leadingGlyph

            TextField("Search or enter address", text: $model.addressDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($addressFocused)
                .onSubmit {
                    submitPulse.toggle()
                    model.navigateSelected()
                }

            if let url = selectedTab.url, url.scheme == "https" {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(addressFocused ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                .animation(.easeOut(duration: 0.12), value: addressFocused)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(addressFocused ? Color.white.opacity(0.06) : Color.clear)
                .blur(radius: 12)
                .animation(.easeOut(duration: 0.18), value: addressFocused)
        }
        .frame(maxWidth: 720)
        .scaleEffect(submitPulse ? 0.985 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.6), value: submitPulse)
        .onChange(of: model.addressFocusToken) { _, _ in
            addressFocused = true
        }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                model.addressDraft = selectedTab.editableAddress
            } else {
                model.addressDraft = selectedTab.displayAddress
            }
        }
        .onChange(of: submitPulse) { _, newValue in
            if newValue {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 240_000_000)
                    submitPulse = false
                }
            }
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if selectedTab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        } else if selectedTab.isArtifact {
            ArtifactMark()
                .foregroundStyle(Palette.textMuted)
                .frame(width: 16, height: 16)
        } else if let host = selectedTab.url?.host(percentEncoded: false), !selectedTab.isHome {
            FaviconView(host: host)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 16, height: 16)
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 6) {
            if selectedTab.isSmartReadEligible {
                if showReaderMode {
                    Button(action: onReaderMode) {
                        Image(systemName: "book.fill")
                    }
                    .buttonStyle(IconButtonStyle(selected: readerActive, size: 28))
                    .help("Reader Mode")
                }

                if showSmartRead {
                    Button(action: onSmartRead) {
                        Image(systemName: "text.magnifyingglass")
                    }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Smart Read")
                }
            }

            if showClipboard {
                Button {
                    isClipboardPopoverPresented.toggle()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(IconButtonStyle(selected: isClipboardPopoverPresented, size: 28))
                .help("Paste with citation")
                .popover(isPresented: $isClipboardPopoverPresented, arrowEdge: .bottom) {
                    CitedClipboardPopoverHost(isPresented: $isClipboardPopoverPresented)
                }
            }

            if showTabRailToggle {
                Button {
                    withAnimation(Motion.springSnap) { model.toggleTabs() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle(selected: model.isTabRailVisible, size: 28))
                .help("Toggle side tabs")
            }

            if showChatToggle {
                Button {
                    withAnimation(Motion.springSnap) { model.toggleChat() }
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(IconButtonStyle(selected: model.isChatVisible, size: 28))
                .help("Toggle AI chat")
            }
        }
    }
}

/// Thin wrapper that owns the popover model so the popover keeps its state
/// across open/close cycles (the model resets `pickedClip` and search when
/// the popover dismisses).
private struct CitedClipboardPopoverHost: View {
    @Binding var isPresented: Bool
    @StateObject private var model = CitedClipboardPopoverModel()

    var body: some View {
        CitedClipboardPopover(model: model) {
            isPresented = false
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                model.reset()
            } else {
                model.reload()
            }
        }
    }
}

struct FaviconView: View {
    let host: String

    var body: some View {
        AsyncImage(url: faviconURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            default:
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    private var faviconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }
}
