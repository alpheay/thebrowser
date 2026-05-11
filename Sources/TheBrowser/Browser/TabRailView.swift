import SwiftUI

struct TabRailView: View {
    @ObservedObject var model: BrowserModel
    @AppStorage(PreferenceKey.magneticTabClusters) private var magneticEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            // Reserve space for traffic lights at the top
            Color.clear
                .frame(height: Metrics.railTopPadding)

            NewTabButton {
                withAnimation(Motion.springSoft) {
                    model.addTab()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            sectionLabel
                .padding(.horizontal, 18)
                .padding(.bottom, 4)

            tabList

            footer
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .frostedRail()
    }

    // MARK: - Section label

    private var sectionLabel: some View {
        HStack(spacing: 8) {
            Text("Tabs")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textFaint)

            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)
                .frame(maxWidth: .infinity)

            Text("\(model.tabs.count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
                .contentTransition(.numericText())
                .animation(Motion.springSnap, value: model.tabs.count)
        }
    }

    // MARK: - Rail items

    /// Pinned single tabs always lead, mirroring how Safari/Chrome stack
    /// their pinned strip. Clusters and their members (always unpinned)
    /// follow in their authoring order. The walk below collapses any
    /// contiguous same-cluster run into a single ``RailItem.cluster``
    /// entry so the renderer doesn't have to manage that bookkeeping.
    private var railItems: [RailItem] {
        let pinnedSingles = model.tabs.filter { $0.isPinned && $0.clusterID == nil }
        let rest = model.tabs.filter { !($0.isPinned && $0.clusterID == nil) }
        var items: [RailItem] = pinnedSingles.map { .tab($0) }

        var index = 0
        while index < rest.count {
            let tab = rest[index]
            if let clusterID = tab.clusterID,
               let cluster = model.cluster(id: clusterID) {
                var members: [BrowserTab] = []
                while index < rest.count, rest[index].clusterID == clusterID {
                    members.append(rest[index])
                    index += 1
                }
                items.append(.cluster(cluster, tabs: members))
            } else {
                items.append(.tab(tab))
                index += 1
            }
        }
        return items
    }

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(railItems) { item in
                    switch item {
                    case .tab(let tab):
                        TabRow(
                            model: model,
                            tab: tab,
                            selected: tab.id == model.selectedTabID,
                            indented: false,
                            magneticEnabled: magneticEnabled
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -4)),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                            )
                        )
                    case .cluster(let cluster, let tabs):
                        ClusterSection(
                            model: model,
                            cluster: cluster,
                            tabs: tabs,
                            magneticEnabled: magneticEnabled
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                removal: .opacity
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .animation(Motion.springSoft, value: railItemsIdentity)
        }
        .scrollIndicators(.hidden)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 8)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 16)
            }
        }
    }

    /// String fingerprint of the rail's structure — used as the animation
    /// trigger so SwiftUI runs a spring whenever a tab joins/leaves a
    /// cluster, even though the underlying ``railItems`` is a computed
    /// array. We can't pass the array itself because identity is what
    /// matters, not value equality.
    private var railItemsIdentity: String {
        railItems.map(\.id).joined(separator: "|")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 7) {
            KeycapHint(text: "⌘B")
            Text("tabs")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            Circle()
                .fill(Palette.textFaint.opacity(0.6))
                .frame(width: 2, height: 2)
                .padding(.horizontal, 1)

            KeycapHint(text: "⌘J")
            Text("chat")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Palette.bg.opacity(0), Palette.bg],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 16)
            .offset(y: -16)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Rail item enum

private enum RailItem: Identifiable {
    case tab(BrowserTab)
    case cluster(TabCluster, tabs: [BrowserTab])

    var id: String {
        switch self {
        case .tab(let tab):
            return "tab-\(tab.id.uuidString)"
        case .cluster(let cluster, let tabs):
            // Embed member ids so re-ordering tabs inside a cluster also
            // changes the identity — keeps SwiftUI's diff honest.
            let members = tabs.map { $0.id.uuidString }.joined(separator: ".")
            return "cluster-\(cluster.id.uuidString)[\(members)]"
        }
    }
}

// MARK: - New tab button

private struct NewTabButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            NewTabButtonLabel(isHovering: isHovering)
        }
        .buttonStyle(NewTabButtonStyle())
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
    }
}

private struct NewTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(Motion.microTap, value: configuration.isPressed)
            .environment(\.isPressed, configuration.isPressed)
    }
}

private struct IsPressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private extension EnvironmentValues {
    var isPressed: Bool {
        get { self[IsPressedKey.self] }
        set { self[IsPressedKey.self] = newValue }
    }
}

private struct NewTabButtonLabel: View {
    var isHovering: Bool
    @Environment(\.isPressed) private var isPressed

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(isPressed ? 90 : 0))
                .animation(Motion.springSnap, value: isPressed)

            Text("New tab")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 4)

            KeycapHint(text: "⌘T")
                .opacity(isHovering ? 1.0 : 0.55)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.surfaceHover : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovering ? Palette.strokeStrong : Palette.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Keycap

private struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Tab row

private struct TabRow: View {
    let model: BrowserModel
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let indented: Bool
    let magneticEnabled: Bool

    @State private var isHovering = false
    @State private var isCloseHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            TabIcon(tab: tab, selected: selected)
                .frame(width: 16, height: 16)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                    .rotationEffect(.degrees(45))
            }

            Spacer(minLength: 4)

            CloseButton(
                isHovering: isCloseHovering,
                rowHovering: isHovering,
                action: closeTab
            )
            .onHover { isCloseHovering = $0 }
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(borderColor, lineWidth: isDropTargeted ? 1.2 : 0)
        )
        .scaleEffect(isDropTargeted ? 1.025 : 1.0)
        .padding(.leading, indented ? 20 : 0)
        .overlay(alignment: .leading) {
            // Cluster indent rail: subtle vertical line that visually
            // attaches this row to its cluster header. Drawn inside the
            // indent gutter so it doesn't push the row content.
            if indented {
                Rectangle()
                    .fill(Palette.strokeStrong)
                    .frame(width: 1.5, height: 18)
                    .padding(.leading, 9)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            withAnimation(Motion.springSoft) {
                model.select(tab)
            }
        }
        .contextMenu {
            if tab.clusterID != nil {
                Button("Remove from group") {
                    withAnimation(Motion.springSoft) { model.detach(tab) }
                }
            }
            Button("Close tab", role: .destructive) {
                withAnimation(Motion.springSoft) { model.close(tab) }
            }
        }
        .draggable(DraggedTabPayload(id: tab.id)) {
            DragPreview(tab: tab)
        }
        .dropDestination(for: DraggedTabPayload.self) { payloads, _ in
            handleDrop(payloads: payloads)
        } isTargeted: { targeting in
            withAnimation(Motion.hoverFade) {
                isDropTargeted = targeting
            }
        }
        .animation(Motion.springSoft, value: selected)
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: isDropTargeted)
    }

    private func handleDrop(payloads: [DraggedTabPayload]) -> Bool {
        guard let payload = payloads.first,
              payload.id != tab.id,
              let source = model.tabs.first(where: { $0.id == payload.id })
        else { return false }
        withAnimation(Motion.springBloom) {
            _ = model.mergeTabs(source: source, into: tab, magneticEnabled: magneticEnabled)
        }
        return true
    }

    private func closeTab() {
        withAnimation(Motion.springSoft) {
            model.close(tab)
        }
    }

    private var rowFill: Color {
        if isDropTargeted { return Palette.surfaceActive }
        if selected { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Color.clear
    }

    private var borderColor: Color {
        isDropTargeted ? Color.white.opacity(0.45) : Color.clear
    }
}

// MARK: - Cluster section

private struct ClusterSection: View {
    let model: BrowserModel
    let cluster: TabCluster
    let tabs: [BrowserTab]
    let magneticEnabled: Bool

    var body: some View {
        VStack(spacing: 2) {
            ClusterHeaderRow(
                model: model,
                cluster: cluster,
                tabs: tabs,
                magneticEnabled: magneticEnabled
            )

            if cluster.isExpanded {
                ForEach(tabs) { tab in
                    TabRow(
                        model: model,
                        tab: tab,
                        selected: tab.id == model.selectedTabID,
                        indented: true,
                        magneticEnabled: magneticEnabled
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -6)),
                            removal: .opacity.combined(with: .offset(y: -4))
                        )
                    )
                }
            }
        }
        .padding(.bottom, cluster.isExpanded ? 4 : 0)
        .animation(Motion.springSoft, value: cluster.isExpanded)
        .animation(Motion.springSoft, value: tabs.count)
    }
}

// MARK: - Cluster header row

private struct ClusterHeaderRow: View {
    let model: BrowserModel
    let cluster: TabCluster
    let tabs: [BrowserTab]
    let magneticEnabled: Bool

    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Chevron(rotated: !cluster.isExpanded)

            StackedFavicons(tabs: tabs)
                .frame(height: 18)

            Text(cluster.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            ZStack {
                CountBadge(count: tabs.count)
                    .opacity(isDropTargeted ? 0 : 1)
                DropMergeIcon()
                    .opacity(isDropTargeted ? 1 : 0)
            }
            .animation(Motion.hoverFade, value: isDropTargeted)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: isDropTargeted ? 1.2 : 1)
        )
        .scaleEffect(isDropTargeted ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            withAnimation(Motion.springSoft) {
                model.toggleClusterExpansion(cluster.id)
            }
        }
        .contextMenu {
            Button(cluster.isExpanded ? "Collapse group" : "Expand group") {
                withAnimation(Motion.springSoft) {
                    model.toggleClusterExpansion(cluster.id)
                }
            }
            Button("Ungroup") {
                withAnimation(Motion.springSoft) {
                    model.dissolveCluster(cluster.id)
                }
            }
            Divider()
            Button("Close all tabs in group", role: .destructive) {
                withAnimation(Motion.springSoft) {
                    model.closeCluster(cluster.id)
                }
            }
        }
        .dropDestination(for: DraggedTabPayload.self) { payloads, _ in
            handleDrop(payloads: payloads)
        } isTargeted: { targeting in
            withAnimation(Motion.hoverFade) {
                isDropTargeted = targeting
            }
        }
        .animation(Motion.springSnap, value: isDropTargeted)
        .animation(Motion.hoverFade, value: isHovering)
    }

    private func handleDrop(payloads: [DraggedTabPayload]) -> Bool {
        guard let payload = payloads.first,
              let source = model.tabs.first(where: { $0.id == payload.id })
        else { return false }
        // Dropping a tab that's already in this cluster is a no-op.
        guard source.clusterID != cluster.id else { return false }
        withAnimation(Motion.springBloom) {
            model.attach(source, to: cluster.id)
        }
        return true
    }

    private var rowFill: Color {
        if isDropTargeted { return Palette.surfaceActive }
        if isHovering { return Palette.surfaceHover }
        return Palette.surface
    }

    private var borderColor: Color {
        if isDropTargeted { return Color.white.opacity(0.45) }
        if isHovering { return Palette.strokeStrong }
        return Palette.stroke
    }
}

// MARK: - Drag preview

private struct DragPreview: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(tab: tab, selected: true)
                .frame(width: 14, height: 14)
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.strokeStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 6)
        .frame(maxWidth: 220)
    }
}

// MARK: - Chevron

private struct Chevron: View {
    let rotated: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotated ? -90 : 0))
            .animation(Motion.springSnap, value: rotated)
    }
}

// MARK: - Stacked favicons (cluster header)

private struct StackedFavicons: View {
    let tabs: [BrowserTab]

    var body: some View {
        HStack(spacing: -7) {
            ForEach(Array(tabs.prefix(3).enumerated()), id: \.offset) { idx, tab in
                FaviconBubble(tab: tab)
                    .zIndex(Double(3 - idx))
            }
        }
    }
}

private struct FaviconBubble: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.bgRaised)
                .frame(width: 20, height: 20)
            Circle()
                .stroke(Palette.stroke, lineWidth: 1)
                .frame(width: 20, height: 20)
            faviconContent
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var faviconContent: some View {
        if let host = tab.url?.host(percentEncoded: false), !tab.isHome {
            FaviconView(host: host)
        } else if tab.isHome {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
    }
}

// MARK: - Cluster count badge

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 18)
            .background(
                Capsule(style: .continuous)
                    .fill(Palette.bgRaised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Palette.stroke, lineWidth: 1)
            )
            .contentTransition(.numericText())
            .animation(Motion.springSnap, value: count)
    }
}

// MARK: - Drop merge icon (cluster header when targeted)

private struct DropMergeIcon: View {
    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 28, height: 18)
            Image(systemName: "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
        }
    }
}

// MARK: - Tab icon

private struct TabIcon: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool

    var body: some View {
        Group {
            if tab.isLoading {
                LoadingPulse(selected: selected)
            } else if let host = tab.url?.host(percentEncoded: false), !tab.isHome {
                FaviconView(host: host)
            } else if tab.isHome {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textMuted)
            } else if tab.isArtifact {
                ArtifactMark()
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textMuted)
            } else {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Close button

private struct CloseButton: View {
    var isHovering: Bool
    var rowHovering: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? Palette.textPrimary : Palette.textMuted)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovering ? Palette.surfaceActive : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(rowHovering ? 1 : 0)
        .scaleEffect(rowHovering ? 1.0 : 0.85)
        .animation(Motion.hoverFade, value: rowHovering)
        .animation(Motion.microTap, value: isHovering)
    }
}

// MARK: - Loading indicator

private struct LoadingPulse: View {
    var selected: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                selected ? Palette.textPrimary : Palette.textSecondary,
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(phase * 360))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
