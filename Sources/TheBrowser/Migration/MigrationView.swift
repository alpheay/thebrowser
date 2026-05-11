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
        ScrollView {
            content
                .padding(.horizontal, presentation == .firstRun ? 44 : 0)
                .padding(.vertical, presentation == .firstRun ? 40 : 0)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(Palette.bg)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 32) {
            header
            sourcePicker
            profilePanel
            dataKindsList
            footerPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MIGRATE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(Palette.textFaint)

                Text("Bring your browser with you")
                    .font(.system(size: presentation == .firstRun ? 30 : 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)

                Text("Import bookmarks and history from your existing browser.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
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

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Source")
            HStack(spacing: 10) {
                ForEach(MigrationSource.allCases) { source in
                    SourceTile(
                        source: source,
                        selected: source == viewModel.selectedSource,
                        action: { viewModel.selectSource(source) }
                    )
                }
            }
        }
    }

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Profile")
                Spacer()
                Button {
                    viewModel.refreshProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 26))
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
                .padding(.horizontal, 12)
                .frame(height: 40)
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

    private var dataKindsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Included")
            VStack(spacing: 0) {
                ForEach(Array(MigrationDataKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    DataKindRow(kind: kind, showsDivider: index < MigrationDataKind.allCases.count - 1)
                }
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.profiles.isEmpty ? "No local \(viewModel.selectedSource.displayName) profile found" : "Ready to migrate")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(viewModel.profiles.isEmpty ? "Install \(viewModel.selectedSource.displayName) or refresh after opening it once." : "Bookmarks and history will be imported into TheBrowser.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer()

            Button {
                viewModel.startMigration()
            } label: {
                HStack(spacing: 6) {
                    Text("Start")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(!viewModel.canStart)
            .opacity(viewModel.canStart ? 1 : 0.45)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(Palette.textFaint)
    }
}

// MARK: - Subviews

private struct SourceTile: View {
    var source: MigrationSource
    var selected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.08) : Palette.bgRaised)
                    Image(systemName: source.symbolName)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    Text(source.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                ZStack {
                    Circle()
                        .stroke(selected ? Palette.textPrimary : Palette.strokeStrong, lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if selected {
                        Circle()
                            .fill(Palette.textPrimary)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Palette.surface : (isHovering ? Palette.surfaceHover.opacity(0.6) : Palette.surface.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }
}

private struct DataKindRow: View {
    var kind: MigrationDataKind
    var showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18, alignment: .center)

                Text(kind.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            if showsDivider {
                Rectangle()
                    .fill(Palette.stroke)
                    .frame(height: 1)
                    .padding(.leading, 44)
            }
        }
    }
}

private struct EmptyProfileState: View {
    var source: MigrationSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.textMuted)
            Text("No \(source.displayName) profiles found on this Mac.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
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

private struct RunningPanel: View {
    var source: MigrationSource

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Palette.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Migrating from \(source.displayName)")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Reading bookmarks and history from the local profile.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer()
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct ResultPanel: View {
    var result: MigrationResult
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Migration complete")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(result.profileName) · \(result.source.displayName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }
                Spacer()
                if let onDone {
                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
            }

            CountGrid(counts: result.counts)

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.warnings, id: \.self) { warning in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.textFaint)
                                .frame(width: 14, height: 14)
                                .background {
                                    Circle().stroke(Palette.strokeStrong, lineWidth: 1)
                                }
                            Text(warning)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct ErrorPanel: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Palette.strokeStrong, lineWidth: 1)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("Migration stopped")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onRetry()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Retry")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.bgRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
    }
}

private struct CountGrid: View {
    var counts: MigrationCounts

    private var rows: [(MigrationDataKind, Int)] {
        [
            (.bookmarks, counts.bookmarks),
            (.history, counts.history)
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.0.id) { index, row in
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: row.0.symbolName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Palette.textMuted)
                    Text("\(row.1)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                    Text(row.0.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .tracking(0.2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .overlay(alignment: .trailing) {
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(Palette.stroke)
                            .frame(width: 1)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
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

// MARK: - Button style

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionButtonBody(configuration: configuration)
    }
}

private struct PrimaryActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.bg)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? Color.white.opacity(0.88) : Color.white)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.microTap, value: configuration.isPressed)
            .animation(Motion.hoverFade, value: isHovering)
            .onHover { isHovering = $0 }
    }
}
