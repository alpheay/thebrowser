import AppKit
import SwiftUI

struct DiscordAccountView: View {
    @ObservedObject var store: DiscordAccountStore
    @AppStorage(PreferenceKey.discordOAuthClientID) private var clientIDPref = ""
    @FocusState private var clientIDFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.isSignedIn {
                signedInBody
            } else if !store.hasClientID {
                setupBody
            } else {
                signedOutBody
            }
        }
        .sheet(item: $store.pendingWebAuth) { request in
            DiscordAuthWebSheet(request: request)
        }
    }

    // MARK: - Signed in

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            DiscordProfileCard(profile: store.profile!, guildCount: store.guilds.count)

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Spacer()
                DiscordSecondaryButton(title: "Sign out") {
                    Task { await store.signOut() }
                }
            }
        }
    }

    // MARK: - Signed out

    private var signedOutBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .center, spacing: 16) {
                DiscordGlyph()
                    .frame(width: 36, height: 36)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.bgRaised)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }

                VStack(spacing: 4) {
                    Text("Connect Discord")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Sign in once. Press ⌘D anywhere in The Browser to open your servers in a clean, native window.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DiscordSignInButton(busy: store.phase == .signingIn) {
                    Task { await store.signIn() }
                }
                .padding(.top, 2)

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
    }

    // MARK: - First-run setup

    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    DiscordGlyph()
                        .frame(width: 22, height: 22)
                        .frame(width: 28, alignment: .center)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect The Browser to Discord")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("OAuth runs entirely inside The Browser — your token lives in macOS Keychain and never leaves this device. We request only the `identify` and `guilds` scopes.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DiscordStepList(steps: [
                    "Open the Discord Developer Portal and create a new Application.",
                    "Under OAuth2 → Redirects, add: thebrowser-discord://oauth/callback",
                    "Copy the Application's Client ID and paste it below."
                ])

                DiscordClientIDField(text: $clientIDPref, focused: $clientIDFocused)

                HStack(spacing: 10) {
                    DiscordOpenPortalButton()
                    DiscordCopyRedirectButton()
                    Spacer()
                    Text(clientIDFooterText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(clientIDValid ? Color(red: 0.6, green: 0.85, blue: 0.6) : Palette.textFaint)
                        .animation(Motion.hoverFade, value: clientIDValid)
                }
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .onAppear { clientIDFocused = true }
    }

    /// Discord client IDs are 17–20 digit snowflakes. Anything else is almost
    /// certainly a paste error (often: the Bot token or Public Key).
    private var clientIDValid: Bool {
        let trimmed = clientIDPref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 17, trimmed.count <= 20 else { return false }
        return trimmed.allSatisfy { $0.isNumber }
    }

    private var clientIDFooterText: String {
        clientIDValid ? "Looks good — press Sign in below." : "Format: 17–20 digit Client ID"
    }
}

// MARK: - Setup helpers

private struct DiscordClientIDField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("1234567890123456789", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .focused(focused)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused.wrappedValue ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: focused.wrappedValue)
    }
}

private struct DiscordOpenPortalButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = URL(string: "https://discord.com/developers/applications") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open Developer Portal")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct DiscordCopyRedirectButton: View {
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(DiscordAuthService.redirectURI, forType: .string)
            withAnimation(Motion.springSnap) { didCopy = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(Motion.hoverFade) { didCopy = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy redirect URI")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct DiscordStepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 18, height: 18)
                        .background {
                            Circle().fill(Palette.bgRaised)
                        }
                        .overlay {
                            Circle().stroke(Palette.stroke, lineWidth: 1)
                        }
                    Text(step)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Profile card

private struct DiscordProfileCard: View {
    let profile: DiscordProfile
    let guildCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            DiscordAvatar(profile: profile, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if let legacy = profile.legacyTag {
                        Text(legacy)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Text("@\(profile.username)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Signed in")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.textFaint)
                HStack(spacing: 5) {
                    DiscordGlyph()
                        .frame(width: 10, height: 10)
                    Text(guildCount == 1 ? "1 server" : "\(guildCount) servers")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

// MARK: - Buttons

private struct DiscordSignInButton: View {
    let busy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                        .frame(width: 18, height: 18)
                } else {
                    DiscordGlyph(monochromeColor: .black)
                        .frame(width: 18, height: 18)
                }
                Text(busy ? "Signing in…" : "Sign in with Discord")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
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
        .opacity(busy ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct DiscordSecondaryButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Palette.surfaceHover : Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

// MARK: - Avatar

struct DiscordAvatar: View {
    let profile: DiscordProfile
    var size: CGFloat = 40

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(profile.initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .overlay {
            Circle()
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .frame(width: size, height: size)
        .task(id: profile.avatarURL) { await loadImage() }
    }

    private func loadImage() async {
        guard let url = profile.avatarURL else {
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

// MARK: - Discord glyph

/// Monochrome treatment of the official Discord mark, rendered from the
/// canonical simple-icons SVG via the shared `BrandMarkShape`. We deliberately
/// stay inside the project's matte palette rather than reach for the brand
/// blurple — the rest of the app is strictly black & white.
struct DiscordGlyph: View {
    var monochromeColor: Color = .white

    var body: some View {
        DiscordMark()
            .foregroundStyle(monochromeColor)
    }
}
