import SwiftUI

struct ThreadPickerView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.stroke)
            threadList
            footer
        }
        .background(Palette.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Threads")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("\(model.availableThreads.count) saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }

            Spacer(minLength: 0)

            Button {
                model.createThreadAndSwitch()
                dismiss()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("New Thread")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.availableThreads) { thread in
                    ThreadPickerRow(
                        thread: thread,
                        selected: thread.id == model.currentThreadID
                    ) {
                        model.switchToThread(id: thread.id)
                        dismiss()
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Keycap(text: "⌘⇧[")
            Text("previous")
            Keycap(text: "⌘⇧]")
            Text("next")
            Spacer(minLength: 0)
            Button(role: .destructive) {
                model.closeCurrentThread()
                dismiss()
            } label: {
                Label("Close Thread", systemImage: "trash")
            }
            .buttonStyle(PillButtonStyle())
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.textFaint)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .overlay(alignment: .top) {
            Divider().overlay(Palette.stroke)
        }
    }
}

private struct ThreadPickerRow: View {
    var thread: ThreadRecord
    var selected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : Palette.textMuted)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if thread.isWindowOpen {
                    Image(systemName: "macwindow")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .help("Open in a window")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Palette.surfaceActive : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        let count = thread.tabs.count
        let tabLabel = count == 1 ? "1 tab" : "\(count) tabs"
        return "\(tabLabel) · \(thread.lastFocusedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct Keycap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            }
    }
}
