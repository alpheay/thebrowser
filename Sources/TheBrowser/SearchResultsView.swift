import SwiftUI

struct SearchResultsView: View {
    var searchPage: BrowserSearchPage
    var reloadToken: Int
    var onOpen: (URL) -> Void

    @State private var state: SearchResultsState = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                    .padding(.top, 32)

                content
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.bottom, 44)
        }
        .background(Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.webviewRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .padding(.horizontal, Metrics.webviewInset)
        .padding(.bottom, Metrics.webviewInset)
        .task(id: "\(searchPage.id)-\(reloadToken)") {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text(providerLabel)
                        .font(Typography.caption)
                }
                .foregroundStyle(Palette.textMuted)

                Text(searchPage.query)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            if let fallbackURL {
                Button {
                    onOpen(fallbackURL)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .help("Open web results")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    SearchResultSkeleton(index: index)
                }
            }
        case .loaded(let response):
            if response.results.isEmpty && response.instantAnswer == nil {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let answer = response.instantAnswer {
                        InstantAnswerView(answer: answer, onOpen: onOpen)
                    }

                    ForEach(response.results) { result in
                        SearchResultRow(result: result) {
                            onOpen(result.url)
                        }
                    }
                }
            }
        case .failed:
            emptyState
        }
    }

    private var providerLabel: String {
        switch state {
        case .loaded(let response):
            return response.providerName
        default:
            return "Search"
        }
    }

    private var fallbackURL: URL? {
        SearchEngine.selected.searchURL(for: searchPage.query)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No native results")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)

            if let fallbackURL {
                Button {
                    onOpen(fallbackURL)
                } label: {
                    Label("Open web results", systemImage: "safari")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: 8)
    }

    @MainActor
    private func load() async {
        state = .loading

        do {
            let response = try await SearchResultsClient.search(query: searchPage.query)
            guard !Task.isCancelled else { return }
            state = .loaded(response)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private enum SearchResultsState: Equatable {
    case idle
    case loading
    case loaded(SearchResponse)
    case failed(String)
}

private struct SearchResultRow: View {
    var result: SearchResult
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                resultGlyph
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(result.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Text("·")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Palette.textPrimary.opacity(0.5))

                        Text(result.displayURL)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }

    @ViewBuilder
    private var resultGlyph: some View {
        if let host = result.url.host(percentEncoded: false) {
            FaviconView(host: host)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 20, height: 20)
        }
    }
}

private struct InstantAnswerView: View {
    var answer: SearchInstantAnswer
    var onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(answer.source)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.textMuted)

                Spacer()

                if let url = answer.url {
                    Button {
                        onOpen(url)
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Open source")
                }
            }

            Text(answer.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Text(answer.text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SearchResultSkeleton: View {
    var index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.surfaceActive.opacity(0.55))
                .frame(width: CGFloat(220 + (index % 3) * 56), height: 15)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.surfaceActive.opacity(0.34))
                .frame(width: CGFloat(150 + (index % 2) * 42), height: 10)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.surfaceActive.opacity(0.42))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
    }
}
