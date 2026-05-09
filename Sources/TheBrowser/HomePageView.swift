import SwiftUI

struct HomePageView: View {
    @State private var query = ""
    var onNavigate: (String) -> Void

    private let quickActions = [
        QuickAction(title: "Open research", subtitle: "Ask, compare, synthesize", symbol: "doc.text.magnifyingglass", destination: "https://www.perplexity.ai"),
        QuickAction(title: "Build with Codex", subtitle: "Local agent workspace", symbol: "terminal", destination: "https://developers.openai.com/codex"),
        QuickAction(title: "Read the web", subtitle: "Start with a clean page", symbol: "safari", destination: "https://news.ycombinator.com"),
        QuickAction(title: "Ship something", subtitle: "Turn intent into tasks", symbol: "hammer", destination: "https://github.com")
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    hero(in: proxy.size)
                    quickActionGrid
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func hero(in size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeroArtwork()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                    Text("Codex-ready native browsing")
                }
                .font(.system(size: 12, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.3)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Palette.pearl)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("The Browser")
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .foregroundStyle(Palette.pearl)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("A vertical, AI-first command surface for browsing, thinking, and handing real work to Codex.")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.pearl.opacity(0.82))
                    .frame(maxWidth: 690, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.86)

                searchBar
                    .frame(maxWidth: 760)
            }
            .padding(34)
        }
        .frame(height: max(430, min(620, size.height * 0.68)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .padding(.top, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.muted)

            TextField("Search, open, or ask where to begin", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.pearl)
                .onSubmit {
                    submit()
                }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(IconButtonStyle(selected: true))
            .help("Go")
        }
        .padding(10)
        .background(Palette.ink.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var quickActionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            ForEach(quickActions) { action in
                Button {
                    onNavigate(action.destination)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            Image(systemName: action.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Palette.saffron)
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Palette.pearl)
                                .lineLimit(1)
                            Text(action.subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .glassPanel()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        onNavigate(trimmed)
    }
}

private struct QuickAction: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var symbol: String
    var destination: String
}

private struct HeroArtwork: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [Palette.graphite, Palette.ink, Color(hex: 0x14201c)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                ))

                for index in 0..<18 {
                    let progress = Double(index) / 18
                    let y = size.height * (0.12 + progress * 0.74)
                    let wave = sin(t / 2 + progress * 8) * size.width * 0.08
                    var path = Path()
                    path.move(to: CGPoint(x: -40, y: y))
                    path.addCurve(
                        to: CGPoint(x: size.width + 40, y: y + CGFloat(sin(progress * 5) * 90)),
                        control1: CGPoint(x: size.width * 0.28 + wave, y: y - 120),
                        control2: CGPoint(x: size.width * 0.68 - wave, y: y + 120)
                    )
                    context.stroke(
                        path,
                        with: .color([Palette.coral, Palette.saffron, Palette.cyan, Palette.plum][index % 4].opacity(0.48)),
                        lineWidth: 1.4
                    )
                }

                let portalRect = CGRect(
                    x: size.width * 0.58,
                    y: size.height * 0.12,
                    width: size.width * 0.32,
                    height: size.height * 0.56
                )
                let portal = Path(roundedRect: portalRect, cornerRadius: 8)
                context.fill(portal, with: .color(Color.white.opacity(0.08)))
                context.stroke(portal, with: .color(Color.white.opacity(0.24)), lineWidth: 1)

                for line in 0..<9 {
                    let y = portalRect.minY + 34 + CGFloat(line * 32)
                    let width = portalRect.width * CGFloat([0.68, 0.42, 0.76, 0.55, 0.72, 0.38, 0.63, 0.5, 0.7][line])
                    let lineRect = CGRect(x: portalRect.minX + 24, y: y, width: width, height: 7)
                    context.fill(
                        Path(roundedRect: lineRect, cornerRadius: 4),
                        with: .color(line % 3 == 0 ? Palette.saffron.opacity(0.58) : Color.white.opacity(0.22))
                    )
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 9) {
                MiniMetric(label: "Tabs", value: "Vertical")
                MiniMetric(label: "Agent", value: "Codex")
                MiniMetric(label: "Mode", value: "Native")
            }
            .padding(18)
        }
    }
}

private struct MiniMetric: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.muted)
                .textCase(.uppercase)
                .tracking(1)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.pearl)
        }
        .frame(width: 150)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.ink.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        }
    }
}
