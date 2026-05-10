import AppKit
import AuthenticationServices
import SwiftUI

struct GoogleAccountView: View {
    @ObservedObject var store: GoogleAccountStore
    @AppStorage(PreferenceKey.googleOAuthClientID) private var clientIDPref = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }

            if !store.isSignedIn {
                clientIDConfigurationCard
            }
        }
    }

    // MARK: - Signed in

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProfileCard(profile: store.profile!)

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Spacer()
                SignOutButton {
                    Task { await store.signOut() }
                }
            }
        }
    }

    // MARK: - Signed out

    private var signedOutBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .center, spacing: 16) {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Palette.textMuted)

                VStack(spacing: 4) {
                    Text("Sign in to The Browser")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Use your Google account to personalize the browser. We only ever read your profile — never your messages or files.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GoogleSignInButton(enabled: store.hasClientID, busy: store.phase == .signingIn) {
                    Task { await performSignIn() }
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

    private func performSignIn() async {
        guard let anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            return
        }
        await store.signIn(anchor: anchor)
    }

    // MARK: - Client ID configuration

    private var clientIDConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OAUTH SETUP")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Palette.textMuted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Google OAuth Client ID")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text("Create an iOS-type OAuth Client ID in the Google Cloud Console, then paste it below. The redirect URI is auto-derived.")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ClientIDField(text: $clientIDPref)

                    HStack(spacing: 12) {
                        OpenConsoleLink()
                        Spacer()
                    }
                }
                .padding(16)
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
        }
    }
}

private struct ClientIDField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("123456789-abcdef.apps.googleusercontent.com", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.bgRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focused ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: focused)
    }
}

private struct OpenConsoleLink: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                Text("Open Google Cloud Console")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

// MARK: - Profile card

private struct ProfileCard: View {
    let profile: GoogleProfile

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Avatar(profile: profile)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 6) {
                    Text(profile.email)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    if profile.verifiedEmail {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
                            .help("Verified by Google")
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Signed in")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Palette.textFaint)
                Text("Google")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
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

private struct Avatar: View {
    let profile: GoogleProfile
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
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .overlay {
            Circle()
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .frame(width: 48, height: 48)
        .task(id: profile.pictureURL) { await loadImage() }
    }

    private func loadImage() async {
        guard let raw = profile.pictureURL, let url = URL(string: raw) else {
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

// MARK: - Buttons

private struct GoogleSignInButton: View {
    let enabled: Bool
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
                    GoogleGlyph()
                        .frame(width: 18, height: 18)
                }
                Text(busy ? "Signing in…" : "Sign in with Google")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isHovering && enabled && !busy ? 0.92 : 1.0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct SignOutButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Sign out")
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

// MARK: - Google "G" glyph

private struct GoogleGlyph: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let blue = Color(red: 66/255, green: 133/255, blue: 244/255)
            let red = Color(red: 234/255, green: 67/255, blue: 53/255)
            let yellow = Color(red: 251/255, green: 188/255, blue: 5/255)
            let green = Color(red: 52/255, green: 168/255, blue: 83/255)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2

            func arcPath(start: Double, end: Double) -> Path {
                var p = Path()
                p.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false
                )
                p.addArc(
                    center: center,
                    radius: radius * 0.45,
                    startAngle: .degrees(end),
                    endAngle: .degrees(start),
                    clockwise: true
                )
                p.closeSubpath()
                return p
            }

            context.fill(arcPath(start: -45, end: 45), with: .color(blue))
            context.fill(arcPath(start: 45, end: 135), with: .color(green))
            context.fill(arcPath(start: 135, end: 225), with: .color(yellow))
            context.fill(arcPath(start: 225, end: 315), with: .color(red))

            let barWidth = radius * 0.95
            let barHeight = radius * 0.32
            let barRect = CGRect(
                x: center.x,
                y: center.y - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            context.fill(Path(barRect), with: .color(blue))
            context.fill(
                Path(CGRect(x: center.x + radius * 0.1, y: center.y - radius * 0.42, width: radius * 0.55, height: radius * 0.42)),
                with: .color(.white)
            )
        }
    }
}
