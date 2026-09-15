import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// How a row decides whether to name a booster.
///
/// The column has three states and only two of them mean anything on screen, which is exactly the
/// kind of thing that reads as correct and renders as "" boosted.
@Suite("Item row boost attribution")
struct ItemRowBoostTests {

    private func status(boostedByName: String?) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        return CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: "A post.",
            contentHTML: "<p>A post.</p>",
            excerpt: "A post.",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            boostedByName: boostedByName
        )
    }

    @Test("A boost names the booster")
    func boostNamesTheBooster() {
        let row = ItemRow(item: status(boostedByName: "Marie Curie"), showsLateArrival: false)

        #expect(row.boostedByForTesting == "Marie Curie")
    }

    /// The backfill writes "" to mean "examined, not a boost". A row that took that literally would
    /// draw the boost icon next to nothing at all.
    @Test("The empty sentinel names nobody")
    func emptySentinelNamesNobody() {
        let row = ItemRow(item: status(boostedByName: ""), showsLateArrival: false)

        #expect(row.boostedByForTesting == nil)
    }

    /// Nil is a row written before the column existed. Until the backfill reaches it there is
    /// nothing to say, and guessing would be worse than silence.
    @Test("An unexamined row names nobody")
    func unexaminedRowNamesNobody() {
        let row = ItemRow(item: status(boostedByName: nil), showsLateArrival: false)

        #expect(row.boostedByForTesting == nil)
    }
}
