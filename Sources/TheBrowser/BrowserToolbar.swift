import SwiftUI

struct BrowserToolbar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.selectedTab.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .help("Back")

                Button {
                    model.selectedTab.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(IconButtonStyle())
                .help("Forward")

                Button {
                    if model.selectedTab.isLoading {
                        model.selectedTab.stopLoading()
                    } else {
                        model.selectedTab.reload()
                    }
                } label: {
                    Image(systemName: model.selectedTab.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .help("Reload")

                Button {
                    model.goHome()
                } label: {
                    Image(systemName: "sparkle")
                }
                .buttonStyle(IconButtonStyle())
                .help("New space")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.muted)

                    TextField("Search or enter address", text: $model.addressDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.pearl)
                        .onSubmit {
                            model.navigateSelected()
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .glassPanel()

                Button {
                    withAnimation(.snappy) {
                        model.toggleTabs()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle(selected: model.isTabRailVisible))
                .help("Toggle side tabs")

                Button {
                    withAnimation(.snappy) {
                        model.toggleChat()
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(IconButtonStyle(selected: model.isChatVisible))
                .help("Toggle AI chat")
            }

            if model.selectedTab.isLoading {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(Palette.saffron)
                            .frame(width: proxy.size.width * max(0.04, model.selectedTab.estimatedProgress))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, model.selectedTab.isLoading ? 6 : 10)
    }
}
