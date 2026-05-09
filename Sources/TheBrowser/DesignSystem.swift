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
    static let ink = Color(hex: 0x090807)
    static let graphite = Color(hex: 0x171311)
    static let panel = Color(hex: 0x211d1a, alpha: 0.74)
    static let stroke = Color.white.opacity(0.11)
    static let pearl = Color(hex: 0xf8f3ea)
    static let muted = Color(hex: 0xb8aca0)
    static let coral = Color(hex: 0xff6f61)
    static let saffron = Color(hex: 0xf6c85f)
    static let mint = Color(hex: 0x8fd19e)
    static let cyan = Color(hex: 0x5ed6d1)
    static let plum = Color(hex: 0xb990ff)
}

struct IconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(selected ? Palette.ink : Palette.pearl)
            .frame(width: 34, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.pearl : Color.white.opacity(configuration.isPressed ? 0.15 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(selected ? 0.34 : 0.12), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.pearl)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 8) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}
