import ReadReadModel
import SwiftUI

/// The preview of a link a post points at, as a box under the post.
///
/// The picture, headline and blurb come from the instance's own `PreviewCard` — built from the
/// target page's oEmbed endpoint or its OpenGraph tags — so drawing this costs one image and no
/// request to the linked site. See ``LinkCard``.
///
/// Interactive: pressing it opens the page it previews. The box was a label at first, on the
/// argument that a timeline row has exactly one tap and it selects the post — but the box states
/// a headline, a site and a picture belonging to somewhere else, which is an invitation to press
/// however it is styled, and a preview that does nothing when pressed reads as broken rather than
/// as restrained.
///
/// The link target is only ever the card's own URL, so a press cannot be captured by the
/// surrounding row. It also goes through the app's `openURL` override, which means it honours the
/// in-app browser setting exactly like a link inside a post does — see `LinkPolicy`.
struct LinkPreviewCard: View {

    let card: LinkCard

    /// The reader's body text size, so the box grows with everything else in the row.
    var scale: TextScale = .standard

    /// Side of the thumbnail.
    ///
    /// A fixed square rather than the image's own shape: a card image is whatever the publisher
    /// chose — a 1200×630 social banner, a square logo, an accidental favicon — and letting each
    /// decide its own height would make every card in a timeline a different size. The headline is
    /// what is being read here; the picture is there to identify the site.
    private static let thumbnailSide: CGFloat = 64

    private static let cornerRadius: CGFloat = 8

    var body: some View {
        // A card with no usable URL still draws — it has a headline worth reading — but it is not
        // pretending to be pressable. `isShowable` keeps that case rare; it does not rule it out.
        if let url = card.url {
            Link(destination: url) { box }
                // The box paints itself. Left to the default style the whole thing would be
                // tinted — headline, blurb and host line — which is the loudest possible way to
                // say "this is somebody else's page".
                .buttonStyle(.plain)
        } else {
            box
        }
    }

    private var box: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                // Plain text, never markup. This is a headline written by a third party and
                // relayed by the instance; `Text` draws it as characters, which is the only
                // treatment it should get.
                Text(card.title)
                    .scaledFont(.subheadline, weight: .semibold, scale: scale)
                    .lineLimit(2)

                if !card.summary.isEmpty {
                    Text(card.summary)
                        .scaledFont(.caption, scale: scale)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let host = card.hostLabel {
                    // Where a tap would actually go, which is the useful thing to print beside
                    // somebody else's headline — a link's text can claim anything.
                    Text(host)
                        .scaledFont(.caption2, scale: scale)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Self.cornerRadius))
        .overlay {
            // A hairline rather than a heavier fill: the box has to read as a quotation of another
            // page inside the row, not as a second row.
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        // One element out loud, in reading order, because that is what it is: a link to a page.
        // Read as three separate labels it interrupts the post it belongs to three times.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The picture, or a glyph in its place.
    ///
    /// The placeholder is drawn rather than the whole card shrinking to fit: plenty of cards have
    /// no usable image — no `og:image`, or one served over plain `http`, which ``LinkCard/imageURL``
    /// refuses — and a card that changes shape depending on that makes a timeline look broken.
    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let url = card.imageURL, let image = RemoteImageStore.timelineMedia.image(for: url) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
        .clipped()
        .clipShape(.rect(cornerRadius: 6))
        // Decorative: the alt text belongs to the publisher and a card never carries one, so
        // anything invented here would be a guess read out as a fact. The label below says what
        // the box is.
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: Text {
        if let host = card.hostLabel {
            Text("Link: \(card.title), on \(host)")
        } else {
            Text("Link: \(card.title)")
        }
    }
}

#if DEBUG
#Preview {
    List {
        LinkPreviewCard(
            card: LinkCard(
                urlString: "https://example.com/a-piece",
                title: "A headline long enough that it has to wrap onto a second line",
                summary: "And a blurb underneath it, of the length publishers actually write.",
                imageURLString: nil
            )
        )
    }
}
#endif
