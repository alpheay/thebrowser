import AppKit
import SwiftUI

/// Full bookmark browser shown when the user opens the bookmarks pane
/// (⌥⌘B). Mirrors ``TabRailView``'s layout: top header, scrollable list,
/// shared dark plate.
struct BookmarksSidebarView: View {
    @ObservedObject var manager: BookmarksManager
    var onOpen: (String) -> Void
    var onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var editingBookmark: Bookmark?

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            tagChips
            list

            if manager.migrationBackfill.isRunning {
                BackfillStatusRow(state: manager.migrationBackfill)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .frostedRail()
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(width: 1)
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditSheet(
                bookmark: bookmark,
                onSave: { update in
                    manager.updateBookmark(
                        id: update.id,
                        title: update.title,
                        folder: update.folder,
                        tags: update.tags,
                        descriptionText: update.descriptionText
                    )
                    editingBookmark = nil
                },
                onCancel: { editingBookmark = nil }
            )
            .frame(width: 460, height: 420)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Bookmarks")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Close bookmarks")
            }
            Text("\(manager.bookmarks.count) saved")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 14)
        .padding(.top, Metrics.railTopPadding)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
            TextField("Search title, URL, tag, description", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Palette.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var tagChips: some View {
        let tags = manager.allTags()
        if tags.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(
                            label: tag,
                            selected: selectedTags.contains(tag),
                            action: {
                                if selectedTags.contains(tag) {
                                    selectedTags.remove(tag)
                                } else {
                                    selectedTags.insert(tag)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 28)
            .padding(.bottom, 6)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                let rows = filteredAndGrouped()
                if rows.isEmpty {
                    EmptyState(hasQuery: !query.isEmpty || !selectedTags.isEmpty)
                        .padding(.top, 24)
                } else {
                    ForEach(rows, id: \.folder) { group in
                        if !group.folder.isEmpty {
                            FolderHeader(name: group.folder, count: group.bookmarks.count)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                        }
                        ForEach(group.bookmarks) { bookmark in
                            BookmarkRow(
                                bookmark: bookmark,
                                onOpen: { onOpen(bookmark.url) },
                                onEdit: { editingBookmark = bookmark },
                                onDelete: { manager.removeBookmark(id: bookmark.id) },
                                onRetag: {
                                    manager.scheduleTagging(
                                        id: bookmark.id,
                                        title: bookmark.title,
                                        url: bookmark.url
                                    )
                                }
                            )
                            .onDrag {
                                NSItemProvider(object: bookmark.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: BookmarkReorderDelegate(
                                target: bookmark,
                                manager: manager
                            ))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let folder: String
        let bookmarks: [Bookmark]
        var id: String { folder }
    }

    private func filteredAndGrouped() -> [Group] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagsArray = Array(selectedTags)
        let rows = (trimmedQuery.isEmpty && tagsArray.isEmpty)
            ? manager.bookmarks
            : manager.search(query: trimmedQuery, tags: tagsArray)

        let rootRows = rows.filter { $0.folder == BookmarkFolders.root }
        let folderRows = rows.filter { $0.folder != BookmarkFolders.root }

        let foldersInOrder = Array(Set(folderRows.map(\.folder))).sorted()
        var groups: [Group] = []
        if !rootRows.isEmpty {
            groups.append(Group(folder: BookmarkFolders.root, bookmarks: rootRows))
        }
        for folder in foldersInOrder {
            let items = folderRows.filter { $0.folder == folder }
            if !items.isEmpty {
                groups.append(Group(folder: folder, bookmarks: items))
            }
        }
        return groups
    }
}

// MARK: - Tag chip

private struct TagChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? Palette.bg : Palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? Color.white : (isHovering ? Palette.surfaceHover : Palette.surface))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(selected ? Color.clear : Palette.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .animation(Motion.springSnap, value: selected)
    }
}

// MARK: - Folder header

private struct FolderHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
            Text(name.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)
            Rectangle()
                .fill(Palette.strokeFaint)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Row

private struct BookmarkRow: View {
    let bookmark: Bookmark
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onRetag: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                if !bookmark.host.isEmpty {
                    FaviconView(host: bookmark.host)
                        .frame(width: 14, height: 14)
                        .padding(.top, 2)
                } else {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 14, height: 14)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bookmark.title.isEmpty ? bookmark.host : bookmark.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        if bookmark.isTagging {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .scaleEffect(0.55)
                                .frame(width: 10, height: 10)
                                .help("Tagging…")
                        }
                    }

                    Text(bookmark.host)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)

                    if !bookmark.descriptionText.isEmpty {
                        Text(bookmark.descriptionText)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    if !bookmark.tags.isEmpty {
                        FlowingTags(tags: bookmark.tags)
                            .padding(.top, 3)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Edit…") { onEdit() }
            Button("Re-tag") { onRetag() }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Text("Delete") }
        }
    }
}

// MARK: - Flowing tag layout

private struct FlowingTags: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Palette.surface)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Palette.stroke, lineWidth: 1)
                    )
            }
            if tags.count > 4 {
                Text("+\(tags.count - 4)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasQuery ? "magnifyingglass" : "bookmark")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Palette.textFaint)
            Text(hasQuery ? "No bookmarks match." : "No bookmarks yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            if !hasQuery {
                Text("Star a page or press ⌥⌘D to add this tab.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - Backfill status

private struct BackfillStatusRow: View {
    let state: BookmarksManager.MigrationBackfillState

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
            Text(state.progressLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Palette.bgRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }
}

// MARK: - Drag-and-drop reorder

/// Lets dropping `bookmark.id` onto another row move the source into the
/// target's folder. Reordering within a folder isn't strictly necessary
/// (rows already sort by `created_at DESC`) so we only support folder
/// moves — the user changes ordering through Edit's folder field.
private struct BookmarkReorderDelegate: DropDelegate {
    let target: Bookmark
    let manager: BookmarksManager

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in
                manager.updateBookmark(id: id, folder: target.folder)
            }
        }
        return true
    }
}

// MARK: - Edit sheet

struct BookmarkEditUpdate: Identifiable {
    let id: String
    var title: String
    var folder: String
    var tags: [String]
    var descriptionText: String
}

struct BookmarkEditSheet: View {
    let bookmark: Bookmark
    var onSave: (BookmarkEditUpdate) -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var folder: String
    @State private var tagsText: String
    @State private var descriptionText: String

    init(bookmark: Bookmark, onSave: @escaping (BookmarkEditUpdate) -> Void, onCancel: @escaping () -> Void) {
        self.bookmark = bookmark
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: bookmark.title)
        _folder = State(initialValue: bookmark.folder)
        _tagsText = State(initialValue: bookmark.tags.joined(separator: ", "))
        _descriptionText = State(initialValue: bookmark.descriptionText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit bookmark")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 26))
            }

            HStack(spacing: 8) {
                if !bookmark.host.isEmpty {
                    FaviconView(host: bookmark.host)
                        .frame(width: 14, height: 14)
                }
                Text(bookmark.url)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            field(label: "Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }

            field(label: "Folder", help: "Leave empty for top level. Type a new name to create a folder.") {
                TextField("Top level", text: $folder)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }

            field(label: "Tags", help: "Comma-separated.") {
                TextField("ai, papers, design", text: $tagsText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }

            field(label: "Description") {
                TextEditor(text: $descriptionText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(height: 70)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                Button("Save") {
                    let tags = tagsText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    onSave(BookmarkEditUpdate(
                        id: bookmark.id,
                        title: title,
                        folder: folder.trimmingCharacters(in: .whitespacesAndNewlines),
                        tags: tags,
                        descriptionText: descriptionText
                    ))
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
        .padding(22)
        .background(Palette.bg)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Palette.textFaint)
            content()
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
            if let help {
                Text(help)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }
}
