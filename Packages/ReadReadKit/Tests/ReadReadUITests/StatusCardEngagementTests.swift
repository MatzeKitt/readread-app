import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Where a card in the reading pane gets its figures from.
///
/// `@MainActor` because `StatusCard` is a `View`. See `StatusMediaLayoutTests`.
@Suite("Status card engagement")
@MainActor
struct StatusCardEngagementTests {

    /// A payload whose figures deliberately differ from the row's, so it is unambiguous which one
    /// a card read.
    private func payload(favourited: Bool) -> Data {
        Data("""
        {
            "id": "2001",
            "uri": "https://mastodon.social/users/a/statuses/2001",
            "created_at": "2026-09-01T09:00:00.000Z",
            "content": "<p>A post.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@a/2001", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 1, "reblogs_count": 2, "favourites_count": 3,
            "favourited": \(favourited), "reblogged": false,
            "edited_at": null, "language": "en",
            "account": {
                "id": "1", "username": "a", "acct": "a", "display_name": "Ada",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            }
        }
        """.utf8)
    }

    private func row(favourited: Bool?, favouriteCount: Int, payloadFavourited: Bool) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        let item = CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: "A post.",
            excerpt: "A post.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            favouriteCount: favouriteCount,
            isFavourited: favourited,
            mastodonPayload: payload(favourited: payloadFavourited)
        )
        // The initialiser writes the flag; nil has to be put back by hand to stand for a row
        // written before the column existed.
        item.isFavourited = favourited
        return item
    }

    /// The case this exists for. The action writes to the row, and the payload is as stale as the
    /// last refresh — so a post liked from the toolbar has to be counted from the row, or the
    /// button says Unlike while the count two inches below it says otherwise.
    @Test("The focused card counts from the store's row, not the stored payload")
    func focusedCardUsesTheRow() {
        let item = row(favourited: true, favouriteCount: 9, payloadFavourited: false)
        let card = StatusCard(status: RenderableStatus(item), emphasis: .focused, row: item)

        #expect(card.engagementForTesting.favouriteCount == 9)
        #expect(card.engagementForTesting.isFavourited)
    }

    /// The posts around it have no row — they are fetched for the thread and never stored — so
    /// they can only come from what the network said.
    @Test("A card with no row falls back to the status it was given")
    func contextCardUsesTheStatus() {
        let item = row(favourited: false, favouriteCount: 9, payloadFavourited: true)
        let card = StatusCard(status: RenderableStatus(item), emphasis: .context)

        // The payload's figures, not the row's.
        #expect(card.engagementForTesting.favouriteCount == 3)
        #expect(card.engagementForTesting.isFavourited)
    }

    @Test("An unexamined row shows no state rather than claiming one")
    func unexaminedRowShowsNoState() {
        let item = row(favourited: nil, favouriteCount: 9, payloadFavourited: true)
        let card = StatusCard(status: RenderableStatus(item), emphasis: .focused, row: item)

        #expect(!card.engagementForTesting.isFavourited)
    }

    /// Read off the payload, which is where it comes from for every post in a conversation.
    @Test("A renderable status carries the reader's own state")
    func renderableStatusCarriesState() {
        let item = row(favourited: false, favouriteCount: 9, payloadFavourited: true)

        #expect(RenderableStatus(item).isFavourited)
        #expect(!RenderableStatus(item).isReblogged)
    }

    /// A row with no payload at all still has to answer, and its columns are the only source.
    @Test("A payload-less row answers from its columns")
    func payloadlessRowAnswersFromColumns() {
        let key = SortKey(millis: 1, id: "s")
        let item = CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: "A post.",
            excerpt: "A post.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            favouriteCount: 5,
            isFavourited: true
        )

        let status = RenderableStatus(item)

        #expect(status.isFavourited)
        #expect(status.favouriteCount == 5)
    }
}
