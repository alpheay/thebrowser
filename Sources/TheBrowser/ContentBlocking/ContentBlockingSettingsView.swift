import SwiftUI

/// Settings pane for content blocking. Bound to the shared
/// ``ContentBlockingController`` so toggles take effect immediately — a flip
/// here recompiles the rule lists and refreshes every live tab.
struct ContentBlockingSettingsContent: View {
    @StateObject private var controller = ContentBlockingController.shared
    @State private var newSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            CBSection("Blocking") {
                CBRow(
                    label: "Block ads & trackers",
                    help: "Filter requests in WebKit before they load. Applies to every tab."
                ) {
                    CBToggle(isOn: Binding(
                        get: { controller.isEnabled },
                        set: { controller.setEnabled($0) }
                    ))
                }
            }

            CBSection("Categories") {
                ForEach(Array(controller.catalog.map(\.category).enumerated()), id: \.element) { index, category in
                    if index > 0 { CBDivider() }
                    CBRow(label: category.title, help: category.detail, symbol: category.symbolName) {
                        CBToggle(isOn: Binding(
                            get: { controller.isEnabled(category) },
                            set: { controller.setCategory(category, enabled: $0) }
                        ))
                    }
                }
            }
            .opacity(controller.isEnabled ? 1 : 0.4)
            .disabled(!controller.isEnabled)

            allowlistSection

            statusFooter
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content Blocking")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("Block ad networks, trackers, and on-page clutter — natively, in every tab.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }

    // MARK: - Allowlist

    private var allowlistSection: some View {
        CBSection("Allowlisted Sites") {
            CBRow(
                label: "Add a site",
                help: "Blocking stays off for these domains and their subdomains."
            ) {
                HStack(spacing: 8) {
                    TextField("example.com", text: $newSite)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.bgRaised)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Palette.stroke, lineWidth: 1)
                        }
                        .onSubmit(addSite)
                    CBSmallButton(title: "Add", action: addSite)
                        .disabled(SiteAllowList.normalize(newSite) == nil)
                }
            }

            if controller.allowedSites.isEmpty {
                CBDivider()
                Text("No allowlisted sites. Blocking is active everywhere.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ForEach(controller.allowedSites, id: \.self) { site in
                    CBDivider()
                    AllowedSiteRow(site: site) { controller.removeAllow(site) }
                }
            }
        }
    }

    private func addSite() {
        let candidate = newSite
        newSite = ""
        controller.allow(candidate)
    }

    // MARK: - Status

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if controller.isCompiling {
                ProgressView()
                    .controlSize(.small)
                Text("Compiling rules…")
            } else if !controller.isEnabled {
                Image(systemName: "shield.slash")
                Text("Blocking is off.")
            } else if !controller.failedListNames.isEmpty {
                Image(systemName: "exclamationmark.shield")
                Text("\(controller.activeRuleCount) rules active; \(controller.failedListNames.count) lists failed.")
            } else {
                Image(systemName: "shield.lefthalf.filled")
                Text("\(controller.activeRuleCount) rules active across \(controller.compiledLists.count) lists.")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Palette.textMuted)
        .help(controller.failedListNames.joined(separator: ", "))
    }
}

// MARK: - Allowed-site row

private struct AllowedSiteRow: View {
    let site: String
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
            Text(site)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                    .frame(width: 22, height: 22)
                    .background {
                        Circle().fill(isHovering ? Palette.surfaceHover : Color.clear)
                    }
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Reusable pieces

private struct CBSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Palette.textFaint)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content()
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
}

private struct CBRow<Content: View>: View {
    let label: String
    var help: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if let help {
                        Text(help)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct CBDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

private struct CBToggle: View {
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.white : Palette.bgRaised)
                    .frame(width: 38, height: 22)
                    .overlay {
                        Capsule().stroke(isOn ? Color.clear : Palette.stroke, lineWidth: 1)
                    }
                Circle()
                    .fill(isOn ? Palette.bg : Palette.textSecondary)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(Motion.springSnap, value: isOn)
            .animation(Motion.hoverFade, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct CBSmallButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.bg)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Color.white : Palette.textPrimary)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
