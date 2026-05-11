import AppKit
import SwiftUI

/// The Cmd+D launcher. Sits in its own `Window` scene so the user can park
/// it on a second monitor and let it live alongside the browser. Reads from
/// the shared `DiscordAccountStore` so the same session powers the Settings
/// panel and this view.
struct DiscordClientView: View {
    @StateObject private var store = DiscordAccountStore.shared

    /// `nil` selects the Home view; otherwise the matching guild renders in
    /// the detail pane. We hold a plain `String?` rather than the guild
    /// itself so that a list refresh which replaces the array doesn't drop
    /// the selection.
    @State private var selectedGuildID: String?
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
                guilds: filteredGuilds,
                selectedGuildID: $selectedGuildID,
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
                if let id = selectedGuildID, let guild = store.guilds.first(where: { $0.id == id }) {
                    DiscordGuildDetail(guild: guild)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .id(guild.id)
                } else {
                    DiscordHomeDetail(
                        profile: store.profile,
                        guilds: store.guilds,
                        query: $query,
                        onSelect: { id in selectedGuildID = id },
                        onRefresh: { Task { await store.refreshGuilds() } },
                        phase: store.phase,
                        lastError: store.lastError
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.springSnap, value: selectedGuildID)
        }
    }

    private var filteredGuilds: [DiscordGuild] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.guilds }
        return store.guilds.filter {
            $0.name.range(of: trimmed, options: .caseInsensitive) != nil
        }
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

// MARK: - Server rail

private struct DiscordServerRail: View {
    let guilds: [DiscordGuild]
    @Binding var selectedGuildID: String?
    let profile: DiscordProfile?
    let onRefresh: () -> Void
    let phase: DiscordAccountStore.Phase

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 38)  // Traffic-light gutter

            DiscordServerRailIcon(
                isSelected: selectedGuildID == nil,
                action: { selectedGuildID = nil },
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

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(guilds) { guild in
                        DiscordServerRailIcon(
                            isSelected: selectedGuildID == guild.id,
                            action: { selectedGuildID = guild.id },
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

private struct DiscordServerRailIcon<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Selection pill — Discord's signature left-edge indicator
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
    let onSelect: (String) -> Void
    let onRefresh: () -> Void
    let phase: DiscordAccountStore.Phase
    let lastError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let profile {
                    DiscordHomeProfileCard(profile: profile, guildCount: guilds.count)
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
                Text("All your Discord servers, one keystroke away.")
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
                        DiscordGuildCard(guild: guild) { onSelect(guild.id) }
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

// MARK: - Guild detail

private struct DiscordGuildDetail: View {
    let guild: DiscordGuild

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 22) {
                    LargeGuildBadge(guild: guild)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(guild.name)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)
                        if guild.owner == true {
                            DiscordPill(text: "OWNER")
                        }
                        if let count = guild.approximateMemberCount {
                            Text("\(count) members")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    DiscordPrimaryButton(title: "Open in Discord", busy: false) {
                        if let url = guild.webURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    DiscordOutlineButton(title: "Copy server ID") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(guild.id, forType: .string)
                    }
                }

                if let features = guild.features, !features.isEmpty {
                    featuresSection(features: features)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func featuresSection(features: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FEATURES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)

            FlowLayout(spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    DiscordPill(text: formatFeature(feature))
                }
            }
        }
    }

    private func formatFeature(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .capitalized
    }
}

private struct LargeGuildBadge: View {
    let guild: DiscordGuild
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(guild.initials)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
        .task(id: guild.iconURL) { await loadImage() }
    }

    private func loadImage() async {
        guard let url = guild.iconURL else { return }
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

// MARK: - Small UI

private struct DiscordPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                Capsule().fill(Palette.bgRaised)
            }
            .overlay {
                Capsule().stroke(Palette.stroke, lineWidth: 1)
            }
    }
}

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

// MARK: - Flow layout

/// Minimal `Layout` that lays children out left-to-right and wraps when a row
/// runs out of horizontal space — used here for the feature-pill cloud.
/// SwiftUI doesn't ship one out of the box, and reaching for a `LazyVGrid`
/// would force a fixed column count.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
