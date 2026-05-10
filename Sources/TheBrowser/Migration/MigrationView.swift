import SwiftUI

enum MigrationPresentation {
    case firstRun
    case settings
}

@MainActor
final class MigrationViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case running
        case succeeded(MigrationResult)
        case failed(String)
    }

    @Published var selectedSource: MigrationSource = .chrome
    @Published var profiles: [BrowserProfile] = []
    @Published var selectedProfileID = ""
    @Published var state: State = .idle

    init() {
        refreshProfiles()
    }

    var selectedProfile: BrowserProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var canStart: Bool {
        selectedProfile != nil && state != .running && state != .scanning
    }

    func selectSource(_ source: MigrationSource) {
        guard selectedSource != source else { return }
        selectedSource = source
        refreshProfiles()
    }

    func refreshProfiles() {
        state = .scanning
        profiles = BrowserMigrationService.profiles(for: selectedSource)
        selectedProfileID = profiles.first?.id ?? ""
        state = .idle
    }

    func startMigration() {
        guard let selectedProfile else { return }
        let source = selectedSource
        state = .running

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await BrowserMigrationService.migrate(source: source, profile: selectedProfile)
                }.value
                state = .succeeded(result)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct MigrationView: View {
    @StateObject private var viewModel = MigrationViewModel()
    var presentation: MigrationPresentation
    var onFinish: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(presentation == .firstRun ? 28 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            sourceGrid
            profilePanel
            importStrip
            footerPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(viewModel.selectedSource.tint.opacity(0.16))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(viewModel.selectedSource.tint)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 7) {
                Text("Migrate From")
                    .font(.system(size: presentation == .firstRun ? 30 : 24, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Bring over the sign-ins, saved passwords, bookmarks, history, and sessions that make a browser feel like yours.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if presentation == .firstRun {
                Button {
                    onFinish?()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Skip migration")
            }
        }
    }

    private var sourceGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            ForEach(MigrationSource.allCases) { source in
                SourceCard(
                    source: source,
                    selected: source == viewModel.selectedSource,
                    action: { viewModel.selectSource(source) }
                )
            }
        }
    }

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Profile", systemImage: "person.text.rectangle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button {
                    viewModel.refreshProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Refresh profiles")
            }

            if viewModel.profiles.isEmpty {
                EmptyProfileState(source: viewModel.selectedSource)
            } else {
                Picker("", selection: $viewModel.selectedProfileID) {
                    ForEach(viewModel.profiles) { profile in
                        Text("\(profile.name)  ·  \(profile.detail)").tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .surfaceCard(radius: 8)
            }
        }
        .padding(14)
        .surfaceCard(radius: 8)
    }

    private var importStrip: some View {
        HStack(spacing: 8) {
            ForEach(MigrationDataKind.allCases) { kind in
                Label(kind.title, systemImage: kind.symbolName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footerPanel: some View {
        switch viewModel.state {
        case .idle, .scanning:
            actionPanel
        case .running:
            RunningPanel(source: viewModel.selectedSource)
        case .succeeded(let result):
            ResultPanel(result: result, onDone: onFinish)
        case .failed(let message):
            ErrorPanel(message: message, onRetry: viewModel.startMigration)
        }
    }

    private var actionPanel: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.profiles.isEmpty ? "No local \(viewModel.selectedSource.displayName) profile found" : "Ready to migrate")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(viewModel.profiles.isEmpty ? "Install \(viewModel.selectedSource.displayName) or refresh after opening it once." : "TheBrowser will import local browser data into WebKit and Keychain.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer()

            Button {
                viewModel.startMigration()
            } label: {
                Label("Start Migration", systemImage: "arrow.down.doc.fill")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!viewModel.canStart)
            .opacity(viewModel.canStart ? 1 : 0.5)
        }
        .padding(14)
        .surfaceCard(radius: 8)
    }
}

private struct SourceCard: View {
    var source: MigrationSource
    var selected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(source.tint.opacity(selected ? 0.26 : 0.14))
                    Image(systemName: source.symbolName)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(source.tint)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 5) {
                    Text(source.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(source.subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? source.tint : Palette.textFaint)
            }
            .padding(12)
            .frame(minHeight: 86)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering || selected ? Palette.surfaceHover : Palette.surface)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(selected ? source.tint : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? source.tint.opacity(0.34) : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }
}

private struct EmptyProfileState: View {
    var source: MigrationSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            Text("No \(source.displayName) profiles were found on this Mac.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Spacer()
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .surfaceCard(radius: 8)
    }
}

private struct RunningPanel: View {
    var source: MigrationSource

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text("Migrating from \(source.displayName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Reading local profile data, importing cookies, and saving passwords to Keychain.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer()
        }
        .padding(14)
        .surfaceCard(radius: 8)
    }
}

private struct ResultPanel: View {
    var result: MigrationResult
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(result.source.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Migration complete")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(result.profileName) from \(result.source.displayName)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }
                Spacer()
                if let onDone {
                    Button {
                        onDone()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }

            CountGrid(counts: result.counts)

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(result.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            }
        }
        .padding(14)
        .surfaceCard(radius: 8)
    }
}

private struct ErrorPanel: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFF6B6B))

            VStack(alignment: .leading, spacing: 5) {
                Text("Migration stopped")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onRetry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(14)
        .surfaceCard(radius: 8)
    }
}

private struct CountGrid: View {
    var counts: MigrationCounts

    private var rows: [(MigrationDataKind, Int)] {
        [
            (.accounts, counts.accounts),
            (.passwords, counts.passwords),
            (.cookies, counts.cookies),
            (.bookmarks, counts.bookmarks),
            (.history, counts.history)
        ]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(rows, id: \.0.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: row.0.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                    Text("\(row.1)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(row.0.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgRaised)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Palette.stroke)
                        .frame(width: 1)
                }
            }
        }
    }
}
