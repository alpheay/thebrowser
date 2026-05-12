import AppKit
import SwiftUI

/// Popover anchored to the downloads chip in ``BrowserToolbar``. Shows
/// active downloads at the top (progress bars + pause/resume/cancel) and
/// recent history below.
struct DownloadsPopover: View {
    @ObservedObject var controller: DownloadController
    var onClose: () -> Void

    private static let popoverCornerRadius: CGFloat = 14

    @State private var nowTick: Date = Date()
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 400)
        .frame(minHeight: 340, maxHeight: 540)
        .background(Palette.bgRaised)
        .overlay {
            RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous))
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text("Downloads")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 0)

            if hasCompletedRows {
                Button {
                    controller.clearCompleted()
                } label: {
                    Text("Clear")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear completed downloads")
            }

            Button {
                NSWorkspace.shared.open(controller.resolvedDownloadsFolder())
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open downloads folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            Rectangle().fill(Palette.bgRaised)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.records.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !activeRecords.isEmpty {
                        sectionLabel("Active")
                            .padding(.top, 12)
                        ForEach(activeRecords) { record in
                            DownloadRow(
                                record: record,
                                controller: controller,
                                now: nowTick
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if record.id != activeRecords.last?.id {
                                Rectangle().fill(Palette.stroke).frame(height: 1).padding(.leading, 12)
                            }
                        }
                    }

                    if !recentRecords.isEmpty {
                        sectionLabel("Recent")
                            .padding(.top, activeRecords.isEmpty ? 12 : 14)
                        ForEach(recentRecords) { record in
                            DownloadRow(
                                record: record,
                                controller: controller,
                                now: nowTick
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if record.id != recentRecords.last?.id {
                                Rectangle().fill(Palette.stroke).frame(height: 1).padding(.leading, 12)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Palette.textFaint)
            Text("No downloads yet")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text("Files you download will show up here.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var activeRecords: [DownloadRecord] {
        controller.records.filter { $0.state.isInFlight }
    }

    private var recentRecords: [DownloadRecord] {
        controller.records.filter { $0.state.isTerminal }
    }

    private var hasCompletedRows: Bool {
        controller.records.contains { $0.state.isTerminal }
    }

    private func startTicker() {
        stopTicker()
        nowTick = Date()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                if !Task.isCancelled { nowTick = Date() }
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }
}

/// Subtle traveling-bar animation for downloads with unknown total size.
private struct IndeterminateBarShimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: proxy.size.width * 0.35)
                .offset(x: (proxy.size.width + proxy.size.width * 0.35) * phase - proxy.size.width * 0.35)
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                }
        }
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    @ObservedObject var controller: DownloadController
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconBadge

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if record.state.isInFlight {
                    progressBar
                    Text(progressSubtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                } else {
                    Text(metadataSubtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let errorMessage = record.errorMessage, record.state == .failed {
                    Text(errorMessage)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(8)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.surfaceHover : Color.clear)
        }
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
            Image(systemName: iconSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                if record.bytesTotal == nil {
                    IndeterminateBarShimmer()
                        .clipShape(Capsule())
                } else {
                    Capsule()
                        .fill(record.state == .paused ? Palette.textMuted : Color.white.opacity(0.85))
                        .frame(width: proxy.size.width * progressFraction)
                        .animation(.easeOut(duration: 0.2), value: progressFraction)
                }
            }
        }
        .frame(height: 4)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            switch record.state {
            case .pending, .active:
                rowButton(symbol: "pause.fill", help: "Pause") {
                    controller.pause(id: record.id)
                }
                rowButton(symbol: "xmark", help: "Cancel") {
                    controller.cancel(id: record.id)
                }
            case .paused:
                rowButton(symbol: "play.fill", help: "Resume") {
                    controller.resume(id: record.id)
                }
                rowButton(symbol: "xmark", help: "Cancel") {
                    controller.cancel(id: record.id)
                }
            case .completed:
                rowButton(symbol: "magnifyingglass", help: "Show in Finder") {
                    controller.showInFinder(id: record.id)
                }
                rowButton(symbol: "arrow.up.right.square", help: "Open") {
                    controller.openFile(id: record.id)
                }
                rowButton(symbol: "trash", help: "Remove from list") {
                    controller.removeFromList(id: record.id)
                }
            case .failed:
                rowButton(symbol: "arrow.clockwise", help: "Retry") {
                    controller.retry(id: record.id)
                }
                rowButton(symbol: "trash", help: "Remove from list") {
                    controller.removeFromList(id: record.id)
                }
            case .cancelled:
                rowButton(symbol: "arrow.clockwise", help: "Retry") {
                    controller.retry(id: record.id)
                }
                rowButton(symbol: "trash", help: "Remove from list") {
                    controller.removeFromList(id: record.id)
                }
            }
        }
    }

    @ViewBuilder
    private func rowButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Derived display

    private var displayName: String {
        let trimmed = record.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let url = URL(string: record.url) {
            return url.lastPathComponent.isEmpty ? record.url : url.lastPathComponent
        }
        return "Download"
    }

    private var progressFraction: Double {
        guard let total = record.bytesTotal, total > 0 else {
            // Indeterminate — animate a half-filled bar instead of jumping.
            return 0.0
        }
        let value = Double(min(record.bytesReceived, total)) / Double(total)
        return max(0, min(1, value))
    }

    private var progressSubtitle: String {
        let received = formatBytes(record.bytesReceived)
        if let total = record.bytesTotal, total > 0 {
            let totalStr = formatBytes(total)
            if record.state == .paused {
                return "Paused — \(received) of \(totalStr)"
            }
            return "\(received) of \(totalStr) • \(eta)"
        }
        if record.state == .paused {
            return "Paused — \(received)"
        }
        return received
    }

    private var metadataSubtitle: String {
        var parts: [String] = []
        parts.append(formatBytes(record.bytesReceived))
        if let host = URL(string: record.url)?.host {
            parts.append(host)
        }
        parts.append(relativeTime(for: record.completedAt ?? record.startedAt))
        return parts.joined(separator: " • ")
    }

    private var eta: String {
        guard let total = record.bytesTotal, total > 0, record.bytesReceived > 0 else {
            return "estimating…"
        }
        // Estimate from raw elapsed time vs. bytes — coarser than a tracked
        // moving average but doesn't require persisting per-tick samples.
        let elapsed = now.timeIntervalSince(record.startedAt)
        guard elapsed > 0.5 else { return "estimating…" }
        let rate = Double(record.bytesReceived) / elapsed
        guard rate > 0 else { return "estimating…" }
        let remaining = Double(total - record.bytesReceived) / rate
        return formatDuration(remaining)
    }

    private var iconSymbol: String {
        switch record.state {
        case .pending, .active, .paused:
            return "arrow.down"
        case .completed:
            return iconForMimeType(record.mimeType)
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark"
        }
    }

    private var iconColor: Color {
        switch record.state {
        case .completed: return Palette.textPrimary
        case .failed: return Color(red: 1.0, green: 0.55, blue: 0.55)
        case .cancelled: return Palette.textMuted
        default: return Palette.textPrimary
        }
    }

    private func iconForMimeType(_ mime: String) -> String {
        let lower = mime.lowercased()
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "play.rectangle" }
        if lower.hasPrefix("audio/") { return "speaker.wave.2" }
        if lower == "application/pdf" { return "doc.richtext" }
        if lower.contains("zip") || lower.contains("compressed") { return "doc.zipper" }
        if lower.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "estimating…" }
        if seconds < 1 { return "<1 s" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            let s = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(m)m \(s)s"
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(h)h \(m)m"
    }
}
