import ReadReadModel
import SwiftUI

/// The media on a post, drawn across the full width of a timeline row.
///
/// Loaded through a `RemoteImageStore` of its own rather than the shared one. The shared instance
/// is sized for favicons — four hundred of them, two megabytes apiece — and pouring timeline media
/// through it would evict every icon in the sidebar to hold pictures nobody is looking at any more.
///
/// Thumbnails come from ``Attachment/previewURL``, which is Mastodon's own scaled copy. Loading the
/// original to draw a couple of hundred points of it would pull megabytes per row.
struct StatusMediaStrip: View {

    let attachments: [Attachment]

    /// Whether the author marked the media sensitive.
    ///
    /// Nothing is drawn when they did. The detail view blurs sensitive media behind a tap, and the
    /// timeline has no equivalent — a row is glanced at, not opened — so the honest options are
    /// "blurred" or "absent", and absent is the one that cannot go wrong while scrolling past.
    let isSensitive: Bool

    /// Optional so the row still renders in a preview or a test that has no shell around it.
    @Environment(MediaViewerModel.self) private var viewer: MediaViewerModel?

    /// Mastodon's own limit is four, so this only ever bites on a post federated from software
    /// that allows more.
    static let maximumShown = 4

    /// The gap between tiles, horizontally and vertically. Small on purpose: the tiles read as one
    /// picture block belonging to the post, not as four separate things.
    private static let spacing: CGFloat = 3

    /// How tall one row of tiles is when a post carries several.
    ///
    /// A fixed height rather than one derived from the tile's own aspect ratio, and the reason is
    /// layout rather than taste. Deriving it needs the width, and a row in a `List` is proposed no
    /// definite height — `aspectRatio(_:contentMode: .fit)` then falls back to the *child's* ideal
    /// height, which for a `Color` is ten points, and the media collapses to a sliver. Measuring
    /// the width instead makes every row resize one frame after it appears, which is the one thing
    /// a scrolling list must not do. `AttachmentGrid` in the reading pane fixes its heights for the
    /// same reason.
    ///
    /// The consequence, stated because it is a real trade: on a wide window the tiles are
    /// letterboxed rather than square. The full-size picture is one click away in the viewer.
    private static let rowHeight: CGFloat = 132

    /// A post with one attachment gets a taller tile, since it has the whole width to itself.
    private static let singleHeight: CGFloat = 210

    /// And a taller one still when the picture is portrait.
    ///
    /// Every tile centre-crops what it cannot fit, so a portrait screenshot in a landscape tile
    /// loses its top and bottom — which on a screenshot is the part carrying the text. This does
    /// not fix that, it just costs the crop less. Read from the attachment's own dimensions, which
    /// Mastodon supplies, so nothing has to be downloaded to decide it.
    private static let singlePortraitHeight: CGFloat = 300

    private var visual: [Attachment] {
        attachments.filter { $0.kind == .image || $0.kind == .gifv || $0.kind == .video }
    }

    var body: some View {
        let shown = Array(visual.prefix(Self.maximumShown))

        if !shown.isEmpty, !isSensitive {
            VStack(spacing: Self.spacing) {
                ForEach(Self.rows(of: shown), id: \.first?.offset) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(row, id: \.offset) { tile in
                            cell(tile.attachment, at: tile.offset, height: height(of: shown))
                        }
                    }
                }
            }
        } else if !shown.isEmpty {
            // Said rather than silently omitted, so a row is not mistaken for a post with no
            // media at all.
            // Tappable, unlike the row's own media: opening it is an explicit request for
            // exactly this post's media, which is the same consent the detail view's "Show Media"
            // button asks for. Glancing past it in a scrolling list is not.
            Button {
                viewer?.present(visual, startingAt: 0)
            } label: {
                // Built from the title/icon closures rather than the `LocalizedStringKey`
                // initialiser: a ternary over two literals is a `String`, which would take `Text`'s
                // verbatim overload and lose both the translation and the plural agreement.
                Label {
                    if shown.count == 1 {
                        Text("Sensitive media")
                    } else {
                        Text("^[\(shown.count) sensitive attachment](inflect: true)")
                    }
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Layout

    /// One attachment and where it sits in the post, so a tile can open the viewer at itself.
    struct Tile: Hashable {
        var offset: Int
        var attachment: Attachment
    }

    /// The tiles in rows of at most two.
    ///
    /// Two per row rather than a `LazyVGrid` of two flexible columns, which is what the reading
    /// pane uses, because of the odd case: a grid gives the third of three attachments half the
    /// width and leaves the other half empty. Rows let the last one span, so a post's media always
    /// reaches both edges — which is the whole point of drawing it this wide.
    static func rows(of shown: [Attachment]) -> [[Tile]] {
        let tiles = shown.enumerated().map { Tile(offset: $0.offset, attachment: $0.element) }
        return stride(from: 0, to: tiles.count, by: 2).map { start in
            Array(tiles[start..<min(start + 2, tiles.count)])
        }
    }

    /// How tall every tile in this post is.
    ///
    /// One height for all of them, including the spanning last one. Sizing a full-width tile to
    /// match the *pair* above it would need the width again (a span is two tiles plus the gap
    /// between them), and a post of three pictures is not worth reintroducing measurement for.
    private func height(of shown: [Attachment]) -> CGFloat {
        guard shown.count == 1 else { return Self.rowHeight }
        return Self.isPortrait(shown[0]) ? Self.singlePortraitHeight : Self.singleHeight
    }

    /// Whether the picture is taller than it is wide.
    ///
    /// `false` when the server did not say, which is the safe way round: the landscape tile is the
    /// shorter one, so an unknown shape costs a crop rather than a row of empty space.
    static func isPortrait(_ attachment: Attachment) -> Bool {
        guard let width = attachment.width, let height = attachment.height, width > 0 else {
            return false
        }
        return height > width
    }

    // MARK: - Tiles

    /// One tile.
    ///
    /// The tile decides its own size and the image is laid *into* it as an overlay. Sizing the
    /// image directly does not work: `scaledToFill` keeps its aspect ratio, so constraining only
    /// the height lets a wide photo claim whatever width it likes and blow the row past the screen
    /// edge. An overlay cannot expand its parent, which is the property being relied on.
    private func cell(_ attachment: Attachment, at offset: Int, height: CGFloat) -> some View {
        // A button, so the click opens the picture instead of selecting the row.
        //
        // That is the convention every Mastodon client follows and the reason it is right here
        // too: a thumbnail is the one part of a row whose obvious meaning is "show me this
        // bigger". The rest of the row still selects the post.
        Button {
            viewer?.present(visual, startingAt: offset)
        } label: {
            Color.clear
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .overlay {
                    // Always the preview, never the original: a Mastodon video or `gifv` *is* an
                    // MP4, which no image decoder will touch, and the full-size original costs
                    // megabytes to draw a couple of hundred points of.
                    if let image = RemoteImageStore.timelineMedia.image(for: attachment.previewURL) {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .overlay {
                    // Marked, because a still frame of a video is indistinguishable from a photo
                    // and the difference decides whether opening it is worth it.
                    if attachment.kind != .image {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // On the last tile rather than beside the block, now that the tiles use the
                    // whole width and there is no "beside" left.
                    if offset == Self.maximumShown - 1, visual.count > Self.maximumShown {
                        Text("+\(visual.count - Self.maximumShown)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .capsule)
                            .padding(6)
                    }
                }
                .clipped()
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(attachment.describedAs.map { Text($0) } ?? Text("Show media"))
        // Mastodon's alt text, which is the whole reason authors write it.
        .accessibilityLabel(attachment.describedAs.map { Text($0) } ?? Text("Attached media"))
    }
}
