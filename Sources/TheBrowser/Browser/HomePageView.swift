import SwiftUI

struct HomePageView: View {
    @State private var query = ""
    @FocusState private var pillFocused: Bool

    var onNavigate: (String) -> Void

    var body: some View {
        ZStack {
            Palette.bg
                .contentShape(Rectangle())
                .onTapGesture {
                    pillFocused = false
                }

            VStack(spacing: 36) {
                Spacer()

                Text("your browser")
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(Palette.textPrimary.opacity(0.92))

                searchPill
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 36)

                Spacer()
                Spacer()
            }
        }
    }

    private var searchPill: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Palette.textMuted)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search, ask, or type a URL")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .focused($pillFocused)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textPrimary)
                    .onSubmit { submit() }
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(pillFocused ? Color.white.opacity(0.18) : Palette.stroke, lineWidth: 1)
                .animation(.easeOut(duration: 0.16), value: pillFocused)
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onNavigate(trimmed)
        query = ""
    }
}

