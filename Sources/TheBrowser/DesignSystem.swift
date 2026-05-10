import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

enum Palette {
    // Plates
    static let bg = Color(hex: 0x0A0A0A)
    static let bgRaised = Color(hex: 0x131313)
    static let bgSunken = Color(hex: 0x050505)

    // Surfaces
    static let surface = Color(hex: 0x181818)
    static let surfaceHover = Color(hex: 0x222222)
    static let surfaceActive = Color(hex: 0x2C2C2C)

    // Strokes
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.14)
    static let strokeFaint = Color.white.opacity(0.04)

    // Text
    static let text = Color.white
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.62)
    static let textMuted = Color.white.opacity(0.40)
    static let textFaint = Color.white.opacity(0.22)

    // Accent — white only
    static let accent = Color.white
    static let accentSoft = Color.white.opacity(0.14)
    static let accentGlow = Color.white.opacity(0.22)
}

enum Typography {
    static let display = Font.system(size: 28, weight: .light, design: .rounded)
    static let wordmark = Font.system(size: 16, weight: .light, design: .rounded)
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13.5, weight: .medium)
    static let label = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
}

enum Motion {
    static let springSnap = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let springSoft = Animation.spring(response: 0.45, dampingFraction: 0.9)
    static let springBloom = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let microTap = Animation.easeOut(duration: 0.12)
    static let hoverFade = Animation.easeOut(duration: 0.14)
}

enum Metrics {
    static let trafficLightGutter: CGFloat = 78
    static let toolbarHeight: CGFloat = 44
    static let railTopPadding: CGFloat = 36
    static let railWidth: CGFloat = 240
    static let chatWidth: CGFloat = 360
    static let webviewInset: CGFloat = 8
    static let webviewRadius: CGFloat = 10
}

struct IconButtonStyle: ButtonStyle {
    var selected = false
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, selected: selected, size: size)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let size: CGFloat
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? Palette.text : Palette.textPrimary)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.microTap, value: configuration.isPressed)
            .animation(Motion.hoverFade, value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var backgroundFill: Color {
        if selected { return Palette.surfaceActive }
        if configuration.isPressed { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? Palette.surfaceHover : Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
            .animation(Motion.hoverFade, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func surfaceCard(radius: CGFloat = 10) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    func frostedRail() -> some View {
        // Side panels share the same plate as the window chrome so they melt
        // seamlessly into the toolbar — no tonal step, no edge.
        background(Palette.bg)
    }

    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: alignment(for: edge)) {
            Group {
                switch edge {
                case .leading, .trailing:
                    Rectangle().fill(Palette.stroke).frame(width: 1)
                case .top, .bottom:
                    Rectangle().fill(Palette.stroke).frame(height: 1)
                }
            }
        }
    }

    private func alignment(for edge: Edge) -> Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    // Preserved for backwards compatibility — same look as surfaceCard now.
    func glassPanel(cornerRadius: CGFloat = 8) -> some View {
        surfaceCard(radius: cornerRadius)
    }
}
