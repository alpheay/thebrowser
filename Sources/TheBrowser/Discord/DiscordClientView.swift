import AppKit
import SwiftUI

/// The Cmd+D launcher. A themed `discord.com` embed in its own window —
/// Discord's own server rail handles navigation, we just supply the matte
/// chrome (title strip, reload, external-open) and the CSS injection that
/// repaints the page in The Browser's palette.
struct DiscordClientView: View {
    @StateObject private var store = DiscordAccountStore.shared
    @State private var didInitialLoad = false

    var body: some View {
        Group {
            if store.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await store.refreshProfile()
            await store.refreshGuilds()
        }
        .sheet(item: $store.pendingWebAuth) { request in
            DiscordAuthWebSheet(request: request)
        }
    }

    // MARK: - Signed in

    private var signedInBody: some View {
        DiscordMessagingPane(
            url: URL(string: "https://discord.com/channels/@me")!
        )
    }

    // MARK: - Signed out

    private var signedOutBody: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            DiscordGlyph()
                .frame(width: 48, height: 48)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.bgRaised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }

            VStack(spacing: 8) {
                Text("Discord")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text(store.hasClientID
                     ? "Sign in to load your servers."
                     : "Open Settings → Account → Discord to connect your account.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)

            if store.hasClientID {
                DiscordPrimaryButton(
                    title: "Sign in with Discord",
                    busy: store.phase == .signingIn
                ) {
                    Task { await store.signIn() }
                }
            } else {
                DiscordOutlineButton(title: "Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Messaging pane

/// Wraps the themed `WKWebView` with a thin native header strip showing the
/// app title plus reload + external-open buttons. Everything else (server
/// rail, channel list, DM list, message view, composer) is Discord's own UI
/// inside the embed.
private struct DiscordMessagingPane: View {
    let url: URL

    @StateObject private var controller = DiscordWebController()

    var body: some View {
        VStack(spacing: 0) {
            DiscordContextHeader(
                externalURL: url,
                loadingState: controller.loadingState,
                onReload: { controller.loadFresh() }
            )
            DiscordWebContent(url: url, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DiscordContextHeader: View {
    let externalURL: URL
    let loadingState: DiscordWebLoadingState
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    DiscordGlyph()
                        .frame(width: 14, height: 14)
                    Text("Discord")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    loadingChip
                }

                Spacer()

                DiscordHeaderIconButton(
                    symbol: "arrow.clockwise",
                    tooltip: "Reload",
                    action: onReload
                )

                DiscordHeaderIconButton(
                    symbol: "arrow.up.right.square",
                    tooltip: "Open in default browser",
                    action: {
                        NSWorkspace.shared.open(externalURL)
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .padding(.leading, 70) // Traffic-light gutter
            .frame(height: 44)

            if case .failed(let message) = loadingState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    Text("Couldn't load Discord — \(message)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(red: 0.18, green: 0.05, blue: 0.05))
            }
        }
        .background(Palette.bgSunken)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }

    @ViewBuilder
    private var loadingChip: some View {
        switch loadingState {
        case .idle, .loaded:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).tint(Palette.textMuted)
                Text("Loading")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.textMuted)
            }
        case .failed:
            Text("FAILED")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
        }
    }
}

private struct DiscordHeaderIconButton: View {
    let symbol: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 28, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isHovering ? Palette.stroke : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

// MARK: - Buttons (shared with signed-out card)

private struct DiscordPrimaryButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isHovering && !busy ? 0.92 : 1.0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct DiscordOutlineButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}
