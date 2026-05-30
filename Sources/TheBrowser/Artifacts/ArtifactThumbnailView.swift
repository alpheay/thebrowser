import SwiftUI

/// The image-or-glyph preview for a single artifact, in a fixed 4:3 frame.
/// Shared by the gallery grid and the home-page strip so both render — and
/// cache — thumbnails identically. Requests a render on appear; until one
/// lands (or if it fails) it shows the artifact spark glyph.
struct ArtifactThumbnailView: View {
    let artifact: ArtifactMetadata
    @ObservedObject var renderer: ArtifactThumbnailRenderer

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.bgRaised)
            if let image = renderer.thumbnail(for: artifact.id) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtifactMark()
                    .foregroundStyle(Palette.textFaint)
                    .scaleEffect(2.2)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipped()
        .onAppear { renderer.request(artifact) }
    }
}
