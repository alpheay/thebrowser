import AppKit
import SwiftUI

/// The horizontal bookmark bar that sits below the address bar. Renders
/// every top-level (root-folder) bookmark as a chip and surfaces named
/// folders as dropdown menus. Visibility is bound to a host @AppStorage
/// flag so ⇧⌘B can toggle it without going through the view tree.
struct BookmarkBarView: View {
    @ObservedObject var manager: BookmarksManager
    /// Called when the user picks a bookmark — usually the host navigates
    /// the selected tab to the chosen URL.
    var onOpen: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let roots = manager.bookmarks.filter { $0.folder == BookmarkFolders.root }
                let folders = Array(Set(manager.bookmarks.map(\.folder)))
                    .filter { !$0.isEmpty }
                    .sorted()

                ForEach(folders, id: \.self) { folder in
                    BookmarkFolderMenu(
                        folder: folder,
                        items: manager.bookmarks.filter { $0.folder == folder },
                        onOpen: onOpen
                    )
                }
                ForEach(roots) { bookmark in
                    BookmarkBarChip(bookmark: bookmark, onOpen: onOpen)
                }

                if roots.isEmpty, folders.isEmpty {
                    EmptyBookmarkBarHint()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(height: 30)
        .background(Palette.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.stroke)
                .frame(height: 1)
        }
    }
}

private struct BookmarkBarChip: View {
    let bookmark: Bookmark
    var onOpen: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onOpen(bookmark.url)
        } label: {
            HStack(spacing: 6) {
                if !bookmark.host.isEmpty {
                    FaviconView(host: bookmark.host)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 12, height: 12)
                }
                Text(bookmark.title.isEmpty ? bookmark.host : bookmark.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Palette.surfaceHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hoverFade, value: isHovering)
        .help(bookmark.title.isEmpty ? bookmark.url : "\(bookmark.title)\n\(bookmark.url)")
        .contextMenu {
            BookmarkContextMenu(bookmark: bookmark, onOpen: onOpen)
        }
    }
}

private struct BookmarkFolderMenu: View {
    let folder: String
    let items: [Bookmark]
    var onOpen: (String) -> Void

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    onOpen(item.url)
                } label: {
                    Label(
                        item.title.isEmpty ? item.host : item.title,
                        systemImage: "globe"
                    )
                }
            }
            if items.isEmpty {
                Text("Empty folder")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                Text(folder)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct EmptyBookmarkBarHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
            Text("Add bookmarks with ⌥⌘D — they'll show up here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }
}

/// Context menu shared by the bar chip and the sidebar row.
struct BookmarkContextMenu: View {
    let bookmark: Bookmark
    var onOpen: (String) -> Void

    var body: some View {
        Button("Open") { onOpen(bookmark.url) }
        Divider()
        Button("Copy link") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(bookmark.url, forType: .string)
        }
        if BookmarksManager.shared.bookmark(forURL: bookmark.url) != nil {
            Button("Re-tag") {
                BookmarksManager.shared.scheduleTagging(
                    id: bookmark.id,
                    title: bookmark.title,
                    url: bookmark.url
                )
            }
        }
        Divider()
        Button(role: .destructive) {
            BookmarksManager.shared.removeBookmark(id: bookmark.id)
        } label: {
            Text("Delete")
        }
    }
}
