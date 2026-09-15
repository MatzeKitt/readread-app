import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Whether a row draws the link preview.
///
/// `@MainActor` because `ItemRow` is a `View`. See `StatusMediaLayoutTests`.
@Suite("Item row link preview")
@MainActor
struct ItemRowLinkCardTests {

    private let card = LinkCard(
        urlString: "https://www.example.com/a-piece",
        title: "The headline of the linked piece",
        summary: "A blurb.",
        imageURLString: "https://cdn.example.com/og.png"
    )

    /// - Parameter warning: The spoiler text. Ingest stores a warned post's *warning* as the title
    ///   and leaves the excerpt empty, precisely so a list can show the warning without the post —
    ///   which is what `hasContentWarning` reads.
    private func post(warning: String? = nil, card: LinkCard?) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        return CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: warning ?? "Look at this.",
            contentHTML: "<p>Look at this.</p>",
            excerpt: warning == nil ? "Look at this." : "",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            linkCard: card
        )
    }

    @Test("An ordinary post shows its link preview")
    func ordinaryPostShowsCard() {
        let row = ItemRow(item: post(card: card), showsLateArrival: false)

        #expect(row.linkCardForTesting == card)
    }

    /// The case worth a test. A card carries the linked page's own headline and picture, so
    /// printing it under a content warning answers the question the author asked not to be
    /// answered — a post warning for a news story and linking to it would have the story's
    /// headline sitting directly underneath the warning.
    @Test("A post behind a content warning shows no link preview")
    func warnedPostHidesCard() {
        let row = ItemRow(item: post(warning: "Politics", card: card), showsLateArrival: false)

        #expect(row.hasContentWarningForTesting)
        #expect(row.linkCardForTesting == nil)
    }

    @Test("A post with no link has nothing to show")
    func cardlessPostShowsNothing() {
        let row = ItemRow(item: post(card: nil), showsLateArrival: false)

        #expect(row.linkCardForTesting == nil)
    }
}

/// What the row draws for a post the reader has already liked or boosted.
///
/// The state used to live only in the context menu's wording, which meant the only way to find out
/// whether a post had been liked was to open a menu on it.
@Suite("Engagement counts")
@MainActor
struct EngagementCountsTests {

    @Test("A strip with nothing in it is not drawn")
    func emptyStripIsNotDrawn() {
        #expect(!EngagementCounts(reblogCount: 0, favouriteCount: 0, replyCount: 0).hasAny)
    }

    @Test("Any one count is enough to draw the strip", arguments: [
        (1, 0, 0),
        (0, 1, 0),
        (0, 0, 1),
    ])
    func anyCountDrawsTheStrip(reblog: Int, favourite: Int, reply: Int) {
        #expect(
            EngagementCounts(reblogCount: reblog, favouriteCount: favourite, replyCount: reply)
                .hasAny
        )
    }

    /// The reader's own state does not conjure a strip out of nothing. A post with no favourites
    /// cannot be one the reader has favourited — liking it makes the count one — so a flag with
    /// three zeroes beside it is stale data, not something to give a line of row height to.
    @Test("A flag on its own does not draw a strip")
    func flagAloneDrawsNothing() {
        #expect(
            !EngagementCounts(
                reblogCount: 0,
                favouriteCount: 0,
                replyCount: 0,
                isFavourited: true,
                isReblogged: true
            ).hasAny
        )
    }

    /// A row written before the columns existed answers nil, and nil has to read as "nothing to
    /// show" rather than as `true`.
    @Test("An unexamined row shows no state")
    func unexaminedRowShowsNoState() {
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
            favouriteCount: 3
        )
        item.isFavourited = nil
        item.isReblogged = nil

        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(row.engagementForTesting.isFavourited == false)
        #expect(row.engagementForTesting.isReblogged == false)
    }

    @Test("A liked post says so on the row")
    func likedPostSaysSo() {
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
            favouriteCount: 4,
            isFavourited: true
        )

        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(row.engagementForTesting.isFavourited)
        #expect(row.engagementForTesting.favouriteCount == 4)
    }
}
