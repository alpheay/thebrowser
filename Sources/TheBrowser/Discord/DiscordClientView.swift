import AppKit
import SwiftUI

/// The Cmd+D launcher. Sits in its own `Window` scene so the user can park
/// it on a second monitor and let it live alongside the browser. Reads from
/// the shared `DiscordAccountStore` so the same session powers the Settings
/// panel and this view.
///
/// Three top-level states, picked by the rail:
///   - `.home`  — native profile + searchable server grid
///   - `.dm`    — themed `WKWebView` at `discord.com/channels/@me`
///   - `.guild` — themed `WKWebView` at `discord.com/channels/{id}`
/// The webview path inherits the OAuth-flow session cookies (same default
/// `WKWebsiteDataStore`), so the user lands on Discord already signed in.
struct DiscordClientView: View {
    @StateObject private var store = DiscordAccountStore.shared

    @State private var selection: DiscordSelection = .home
    @State private var didInitialLoad = false
    @State private var query = ""

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
        HStack(spacing: 0) {
            DiscordServerRail(
                guilds: store.guilds,
                selection: $selection,
                profile: store.profile,
                onRefresh: { Task { await store.refreshGuilds() } },
                phase: store.phase
            )
            .frame(width: 72)
            .frame(maxHeight: .infinity)
            .background(Palette.bgSunken)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.stroke).frame(width: 1)
            }

            ZStack {
                if let url = selection.webURL {
                    DiscordMessagingPane(
                        url: url,
                        selection: selection,
                        guild: currentGuild
                    )
                    .transition(.opacity)
                } else {
                    DiscordHomeDetail(
                        profile: store.profile,
                        guilds: store.guilds,
                        query: $query,
                        onSelectGuild: { id in selection = .guild(id) },
                        onSelectDMs: { selection = .dm },
                        onRefresh: { Task { await store.refreshGuilds() } },
                        phase: store.phase,
                        lastError: store.lastError
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.springSnap, value: selection.isHome)
        }
    }

    private var currentGuild: DiscordGuild? {
        if case .guild(let id) = selection {
            return store.guilds.first(where: { $0.id == id })
        }
        return nil
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

// MARK: - Selection

enum DiscordSelection: Hashable {
    case home
    case dm
    case guild(String)

    var isHome: Bool {
        if case .home = self { return true }
        return false
    }

    /// The Discord URL that backs this selection. `nil` for Home (no webview).
    var webURL: URL? {
        switch self {
        case .home:
            return nil
        case .dm:
            return URL(string: "https://discord.com/channels/@me")
        case .guild(let id):
            return URL(string: "https://discord.com/channels/\(id)")
        }
    }
}

// MARK: - Messaging pane

/// Wraps the themed `WKWebView` with a thin native header strip showing the
/// current context (DM label or guild metadata) plus an external-open button
/// for falling through to the OS default browser.
private struct DiscordMessagingPane: View {
    let url: URL
    let selection: DiscordSelection
    let guild: DiscordGuild?

    var body: some View {
        VStack(spacing: 0) {
            DiscordContextHeader(
                title: title,
                subtitle: subtitle,
                externalURL: url
            )
            DiscordWebContent(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var title: String {
        switch selection {
        case .home: return ""
        case .dm: return "Direct Messages"
        case .guild:
            return guild?.name ?? "Server"
        }
    }

    private var subtitle: String? {
        switch selection {
        case .home, .dm:
            return nil
        case .guild:
            guard let guild else { return nil }
            var parts: [String] = []
            if guild.owner == true { parts.append("Owner") }
            if let count = guild.approximateMemberCount {
                parts.append("\(count) members")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

private struct DiscordContextHeader: View {
    let title: String
    let subtitle: String?
    let externalURL: URL

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }
            }

            Spacer()

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
        .frame(height: 44)
        .background(Palette.bgSunken)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
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

// MARK: - Server rail

private struct DiscordServerRail: View {
    let guilds: [DiscordGuild]
    @Binding var selection: DiscordSelection
    let profile: DiscordProfile?
    let onRefresh: () -> Void
    let phase: DiscordAccountStore.Phase

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 38)  // Traffic-light gutter

            DiscordServerRailIcon(
                isSelected: selection == .home,
                action: { selection = .home },
                content: {
                    if let profile {
                        DiscordAvatar(profile: profile, size: 44)
                    } else {
                        Image(systemName: "house.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                    }
                },
                tooltip: "Home"
            )

            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 30, height: 1)
                .padding(.vertical, 10)

            DiscordServerRailIcon(
                isSelected: selection == .dm,
                action: { selection = .dm },
                content: { DMRailBadge() },
                tooltip: "Direct Messages"
            )
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(guilds) { guild in
                        DiscordServerRailIcon(
                            isSelected: selection == .guild(guild.id),
                            action: { selection = .guild(guild.id) },
                            content: { GuildBadge(guild: guild) },
                            tooltip: guild.name
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            DiscordRefreshChip(busy: phase == .loadingGuilds || phase == .refreshing, action: onRefresh)
                .padding(.bottom, 14)
        }
    }
}

private struct DMRailBadge: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(width: 44, height: 44)
    }
}

private struct DiscordServerRailIcon<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Capsule()
                    .fill(Palette.textPrimary)
                    .frame(width: 3, height: indicatorHeight)
                    .opacity(indicatorOpacity)
                    .animation(Motion.springSnap, value: isSelected)
                    .animation(Motion.hoverFade, value: isHovering)

                Spacer().frame(width: 8)

                content()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(isSelected ? 0.35 : 0), radius: 6, x: 0, y: 4)

                Spacer().frame(width: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
        .animation(Motion.springSnap, value: isSelected)
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var cornerRadius: CGFloat {
        isSelected ? 14 : (isHovering ? 14 : 22)
    }

    private var indicatorHeight: CGFloat {
        if isSelected { return 28 }
        if isHovering { return 14 }
        return 6
    }

    private var indicatorOpacity: Double {
        if isSelected { return 1 }
        if isHovering { return 0.7 }
        return 0
    }
}

private struct GuildBadge: View {
    let guild: DiscordGuild
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(guild.initials)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(width: 44, height: 44)
        .task(id: guild.iconURL) { await loadImage() }
    }

    private func loadImage() async {
        guard let url = guild.iconURL else {
            image = nil
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let nsImage = NSImage(data: data) {
                image = nsImage
            }
        } catch {
            image = nil
        }
    }
}

private struct DiscordRefreshChip: View {
    let busy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.textPrimary)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Refresh servers")
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

// MARK: - Home detail

private struct DiscordHomeDetail: View {
    let profile: DiscordProfile?
    let guilds: [DiscordGuild]
    @Binding var query: String
    let onSelectGuild: (String) -> Void
    let onSelectDMs: () -> Void
    let onRefresh: () -> Void
    let phase: DiscordAccountStore.Phase
    let lastError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let profile {
                    DiscordHomeProfileCard(
                        profile: profile,
                        guildCount: guilds.count,
                        onOpenDMs: onSelectDMs
                    )
                }

                serversSection
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Home")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("Pick a server or open Direct Messages.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer()
            DiscordOutlineButton(title: "Open Discord Web") {
                if let url = URL(string: "https://discord.com/channels/@me") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SERVERS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Palette.textFaint)
                Spacer()
                DiscordSearchField(query: $query)
                    .frame(width: 220)
            }

            if filteredGuilds.isEmpty {
                emptyServers
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 14) {
                    ForEach(filteredGuilds) { guild in
                        DiscordGuildCard(guild: guild) { onSelectGuild(guild.id) }
                    }
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
            }
        }
    }

    private var emptyServers: some View {
        VStack(spacing: 10) {
            DiscordGlyph()
                .frame(width: 28, height: 28)
                .opacity(0.5)
            Text(query.isEmpty ? (phase == .loadingGuilds ? "Loading your servers…" : "No servers yet.") : "No servers match “\(query)”.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            if query.isEmpty && phase != .loadingGuilds {
                DiscordOutlineButton(title: "Refresh", action: onRefresh)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    private var filteredGuilds: [DiscordGuild] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return guilds }
        return guilds.filter {
            $0.name.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }
}

private struct DiscordHomeProfileCard: View {
    let profile: DiscordProfile
    let guildCount: Int
    let onOpenDMs: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            DiscordAvatar(profile: profile, size: 56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if let legacy = profile.legacyTag {
                        Text(legacy)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Text("@\(profile.username)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer()

            DiscordPrimaryButton(title: "Open DMs", busy: false, action: onOpenDMs)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(guildCount)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .monospacedDigit()
                Text(guildCount == 1 ? "server" : "servers")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

// MARK: - Guild card (grid tile)

private struct DiscordGuildCard: View {
    let guild: DiscordGuild
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                GuildBadge(guild: guild)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(guild.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(subline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
                    .opacity(isHovering ? 1 : 0.4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var subline: String {
        if guild.owner == true { return "Owner" }
        if let count = guild.approximateMemberCount {
            return "\(count) members"
        }
        return "Member"
    }
}

// MARK: - Small UI

private struct DiscordSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            TextField("Find a server", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .focused($focused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        }
        .animation(Motion.hoverFade, value: focused)
    }
}

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
