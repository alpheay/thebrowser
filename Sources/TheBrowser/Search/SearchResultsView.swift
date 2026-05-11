import SwiftUI

struct SearchResultsView: View {
    var searchPage: BrowserSearchPage
    var reloadToken: Int
    var onOpen: (URL) -> Void

    @AppStorage(PreferenceKey.aiProvider) private var aiProvider = AIProviderKind.codex.rawValue

    @State private var state: SearchResultsState = .idle
    @State private var aiPhase: AIAnswerPhaseState = .hidden

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                    .padding(.top, 32)

                aiAnswerSection

                content
            }
            .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
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

    @ViewBuilder
    private var aiAnswerSection: some View {
        switch aiPhase {
        case .hidden:
            EmptyView()
        case .loading(let urls, let titles):
            AIAnswerView(
                phase: .loading,
                citationURLs: urls,
                citationTitles: titles,
                providerName: provider.displayName,
                modelName: modelDisplayLabel,
                onOpenSource: onOpen
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity
            ))
        case .loaded(let answer, let urls, let titles):
            AIAnswerView(
                phase: .loaded(answer),
                citationURLs: urls,
                citationTitles: titles,
                providerName: provider.displayName,
                modelName: modelDisplayLabel,
                onOpenSource: onOpen
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity
            ))
        case .failed:
            EmptyView()
        }
    }

    private var provider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? .codex
    }

    /// AI summaries use the provider's fast/lightweight model, not the user's
    /// primary chat model — surface that in the badge so the source of the
    /// answer is unambiguous.
    private var modelDisplayLabel: String {
        let fastID = provider.fastModelID
        return AIModelOption.find(provider: provider, modelID: fastID)?.displayName ?? fastID
    }

    @MainActor
    private func load() async {
        let isQuestion = QuestionDetector.isQuestion(searchPage.query)

        // Hydrate AI cache up front so back-nav and reload paint the prior
        // answer before the search call even returns — no spinner, no
        // re-prompt. The actor read is a dictionary lookup, so the suspend
        // is sub-millisecond and the cached answer effectively appears with
        // the rest of the view.
        let cachedAnswer = isQuestion
            ? await AIAnswerCache.shared.entry(for: searchPage.query)
            : nil
        if let cachedAnswer {
            aiPhase = .loaded(
                answer: cachedAnswer.answer,
                urls: cachedAnswer.citationURLs,
                titles: cachedAnswer.citationTitles
            )
        } else {
            // Reset stale state on cache miss — without this, the previous
            // query's citations would flash above the new search results.
            aiPhase = .hidden
        }

        state = .loading

        do {
            let response = try await SearchResultsClient.search(query: searchPage.query)
            guard !Task.isCancelled else { return }
            state = .loaded(response)

            // Cached answer is already on screen — search results refresh
            // independently below, but the model does not get re-prompted.
            if cachedAnswer != nil { return }

            guard isQuestion, !response.results.isEmpty else { return }

            let urls = AIAnswerClient.citationURLs(for: response.results)
            let titles = response.results.prefix(urls.count).map(\.title)
            withAnimation(Motion.springSoft) {
                aiPhase = .loading(urls: urls, titles: titles)
            }

            do {
                let answer = try await AIAnswerClient.answer(
                    question: searchPage.query,
                    results: response.results
                )
                guard !Task.isCancelled else { return }
                withAnimation(Motion.springSoft) {
                    aiPhase = .loaded(answer: answer, urls: urls, titles: titles)
                }
                await AIAnswerCache.shared.set(
                    .init(answer: answer, citationURLs: urls, citationTitles: titles),
                    for: searchPage.query
                )
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation(Motion.springSoft) {
                    aiPhase = .failed
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            // If the search fetch fails but a cached AI answer is already
            // rendered, leave it in place — it's still useful on its own.
            if cachedAnswer == nil {
                aiPhase = .hidden
            }
        }
    }
}

private enum SearchResultsState: Equatable {
    case idle
    case loading
    case loaded(SearchResponse)
    case failed(String)
}

private enum AIAnswerPhaseState: Equatable {
    case hidden
    case loading(urls: [URL], titles: [String])
    case loaded(answer: String, urls: [URL], titles: [String])
    case failed
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
