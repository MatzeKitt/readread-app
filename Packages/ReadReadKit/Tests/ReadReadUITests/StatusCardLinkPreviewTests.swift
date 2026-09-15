import Foundation
import MastodonAPI
import ReadReadModel
import Testing

@testable import ReadReadUI

/// The link preview in the reading pane.
///
/// The card was drawn in the timeline row and nowhere else, so tapping a post to read it properly
/// *lost* the preview of the page it pointed at — the one view where there is room for it. What
/// makes that possible to get wrong quietly is that `RenderableStatus` is assembled from two
/// unrelated sources: the post being read comes from the store, the posts around it in a thread
/// come straight off the network, and a card wired into only one of them looks like it works.
@Suite("Reading pane link preview")
struct StatusCardLinkPreviewTests {

    private let card = LinkCard(
        urlString: "https://www.example.com/a-piece",
        title: "The headline of the linked piece",
        summary: "A blurb.",
        imageURLString: "https://cdn.example.com/og.png"
    )

    /// The branch that runs for a row whose payload is missing or will not decode.
    ///
    /// Worth its own test rather than trusting the read: it goes through a memberwise initialiser
    /// with twenty-odd arguments, and putting one in the wrong slot is both easy and silent.
    @Test("A stored post with no payload still shows its card")
    func storedRowCarriesItsCard() {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        let item = CachedItem(
            id: "mastodon:acct:1",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: "Look at this.",
            excerpt: "Look at this.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            linkCard: card
        )

        #expect(RenderableStatus(item).linkCard == card)
    }

    @Test("A post fetched from the instance carries the instance's card")
    func networkStatusCarriesItsCard() throws {
        let status = try decode(Self.status(id: "1", card: Self.cardJSON))

        let rendered = RenderableStatus(status)
        #expect(rendered.linkCard?.urlString == "https://www.example.com/a-piece")
        #expect(rendered.linkCard?.title == "The headline of the linked piece")
        #expect(rendered.linkCard?.imageURLString == "https://cdn.example.com/og.png")
    }

    /// A boost is a wrapper with no content of its own, so its `card` is always null — reading the
    /// card off the outer status rather than the displayed one drops the preview from every
    /// boosted post, which is a large share of a timeline.
    @Test("A boost shows the boosted post's card, not the wrapper's")
    func boostCarriesTheInnerCard() throws {
        let inner = Self.status(id: "1", card: Self.cardJSON)
        let status = try decode(Self.status(id: "2", card: "null", reblog: inner))

        #expect(RenderableStatus(status).linkCard?.title == "The headline of the linked piece")
    }

    /// Instances do produce cards with nothing in them — a link whose target answered with no
    /// title — and a box with an empty headline in it reads as a bug. The pane checks
    /// `isShowable` before drawing; this pins the value that check is made against.
    @Test("A post that links to nothing has no card")
    func cardlessStatusHasNoCard() throws {
        let status = try decode(Self.status(id: "1", card: "null"))

        #expect(RenderableStatus(status).linkCard == nil)
    }

    // MARK: - Fixtures

    private func decode(_ json: String) throws -> MastodonStatus {
        try JSONDecoder.mastodon.decode(MastodonStatus.self, from: Data(json.utf8))
    }

    private static let cardJSON = """
        {
          "url": "https://www.example.com/a-piece",
          "title": "The headline of the linked piece",
          "description": "A blurb.",
          "type": "link",
          "image": "https://cdn.example.com/og.png",
          "provider_name": ""
        }
        """

    /// The smallest status the decoder accepts, which is what keeps this readable — every field
    /// here is one the DTO declares non-optional.
    private static func status(id: String, card: String, reblog: String? = nil) -> String {
        """
        {
          "id": "\(id)",
          "uri": "https://example.social/users/a/statuses/\(id)",
          "created_at": "2026-01-01T10:00:00.000Z",
          "account": {
            "id": "7",
            "username": "a",
            "acct": "a@example.social",
            "display_name": "A",
            "avatar": "https://example.social/avatar.png",
            "url": "https://example.social/@a"
          },
          "content": "<p>Look at <a href=\\"https://www.example.com/a-piece\\">this</a>.</p>",
          "visibility": "public",
          "sensitive": false,
          "spoiler_text": "",
          "media_attachments": [],
          "emojis": [],
          "tags": [],
          "mentions": [],
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "card": \(card),
          "reblog": \(reblog ?? "null")
        }
        """
    }
}
