import AppKit
import SwiftUI

struct GoogleAccountView: View {
    @ObservedObject var store: GoogleAccountStore
    @AppStorage(PreferenceKey.googleOAuthClientID) private var clientIDPref = ""
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
            GoogleAuthWebSheet(request: request)
        }
    }

    // MARK: - Signed in

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProfileCard(profile: store.profile!) {
                Task { await store.signOut() }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                GoogleSignInButton(enabled: true, busy: store.phase == .signingIn) {
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
        await store.signIn()
    }

    // MARK: - First-run setup

    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 28, alignment: .center)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect The Browser to Google")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("Sign-in runs through Google's standard OAuth flow inside The Browser. Your Google session cookies stay in the browser, so YouTube, Gmail, and other Google services are signed in automatically afterwards.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                StepList(steps: [
                    "Open the Google Cloud Console and create an OAuth Client ID of type iOS.",
                    "Use the Bundle ID com.thebrowser (or any value — it isn't validated for native flows).",
                    "Paste the Client ID below. The redirect URI is auto-derived."
                ])

                ClientIDField(text: $clientIDPref, focused: $clientIDFocused)

                HStack(spacing: 10) {
                    OpenConsoleButton()
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

    private var clientIDValid: Bool {
        clientIDPref
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(".apps.googleusercontent.com")
    }

    private var clientIDFooterText: String {
        clientIDValid ? "Looks good — open the Account tab to sign in." : "Format: <prefix>.apps.googleusercontent.com"
    }
}

// MARK: - Setup helpers

private struct ClientIDField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("123456789-abcdef.apps.googleusercontent.com", text: $text)
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

private struct OpenConsoleButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = URL(string: "https://console.cloud.google.com/apis/credentials/oauthclient") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open Google Cloud Console")
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

private struct StepList: View {
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

private struct ProfileCard: View {
    let profile: GoogleProfile
    let onSignOut: () -> Void

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

            SignOutButton(action: onSignOut)
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
                        .fill(isHovering ? Palette.surfaceHover : Palette.bgRaised)
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
