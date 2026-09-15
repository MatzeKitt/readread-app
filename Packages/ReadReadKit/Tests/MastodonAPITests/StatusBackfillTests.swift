import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import MastodonAPI

/// Tests for the pass that fills in columns added after rows were written.
///
/// Worth pinning down because the mechanism is a loop over a predicate that the loop itself has to
/// falsify. Get that wrong and it does not fail loudly: it fetches, decodes and saves the same two
/// hundred rows for ever, on the main launch path, in a build that otherwise looks fine.
@Suite("Status backfill")
struct StatusBackfillTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    /// A status as the store keeps it: whole, and re-decodable.
    private func payload(boostedBy: String?) -> Data {
        let inner = """
        {
            "id": "2001",
            "uri": "https://other.example/users/orig/statuses/2001",
            "created_at": "2026-01-01T00:00:00.000Z",
            "content": "<p>The original text.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://other.example/@orig/2001", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 1, "reblogs_count": 2, "favourites_count": 3,
            "edited_at": null, "language": "en",
            "account": {
                "id": "3", "username": "orig", "acct": "orig@other.example",
                "display_name": "Original Author",
                "avatar": "https://files.example/o.png", "avatar_static": null,
                "url": "https://other.example/@orig", "bot": false, "emojis": []
            }
        }
        """

        guard let boostedBy else { return Data(inner.utf8) }

        let wrapper = """
        {
            "id": "3001",
            "uri": "https://mastodon.social/users/b/statuses/3001/activity",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [],
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": null, "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "edited_at": null, "language": null,
            "account": {
                "id": "2", "username": "booster", "acct": "booster",
                "display_name": "\(boostedBy)",
                "avatar": "https://files.example/b.png", "avatar_static": null,
                "url": "https://mastodon.social/@booster", "bot": false, "emojis": []
            },
            "reblog": \(inner)
        }
        """
        return Data(wrapper.utf8)
    }

    private func row(id: String, payload: Data?) -> CachedItem {
        CachedItem(
            id: id,
            sourceID: "mastodon:\(accountID):home",
            accountID: accountID,
            kind: .status,
            title: "The original text.",
            excerpt: "The original text.",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: id),
            ingestKey: SortKey(millis: 1_700_000_000_000, id: id),
            mastodonPayload: payload
        )
    }

    private func make(_ rows: [CachedItem]) throws -> (StatusBackfill, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        for row in rows { context.insert(row) }
        try context.save()
        return (StatusBackfill(modelContainer: container), container)
    }

    private func stored(_ id: String, in container: ModelContainer) throws -> CachedItem? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The point of the whole pass: a post already in the store is never fetched again, so without
    /// this the booster's name would appear only on posts that arrive after the update.
    @Test("A boost already in the store gains its attribution")
    func boostIsBackfilled() async throws {
        let (backfill, container) = try make([row(id: "a", payload: payload(boostedBy: "Marie Curie"))])

        let updated = try await backfill.fillMissingBoostAttribution()

        #expect(updated == 1)
        #expect(try stored("a", in: container)?.boostedByName == "Marie Curie")
    }

    /// The empty string is load-bearing, not tidiness. Most posts are not boosts, so leaving them
    /// nil would leave them matching the predicate — the same batch fetched and decoded on every
    /// pass, for ever.
    @Test("A post that is not a boost is recorded as answered")
    func plainPostIsMarkedAnswered() async throws {
        let (backfill, container) = try make([row(id: "b", payload: payload(boostedBy: nil))])

        let updated = try await backfill.fillMissingBoostAttribution()

        // Not counted as an update — nothing was recovered — but written all the same.
        #expect(updated == 0)
        #expect(try stored("b", in: container)?.boostedByName == "")
    }

    @Test("A second pass finds nothing left to do")
    func secondPassIsEmpty() async throws {
        let (backfill, _) = try make([
            row(id: "a", payload: payload(boostedBy: "Marie Curie")),
            row(id: "b", payload: payload(boostedBy: nil)),
        ])

        _ = try await backfill.fillMissingBoostAttribution()

        #expect(try await backfill.fillMissingBoostAttribution() == 0)
    }

    /// A payload that will not decode cannot be recovered from, and has to leave the search anyway.
    @Test("An undecodable payload is answered rather than retried")
    func undecodablePayloadIsAnswered() async throws {
        let (backfill, container) = try make([row(id: "c", payload: Data("{ not json".utf8))])

        _ = try await backfill.fillMissingBoostAttribution()

        #expect(try stored("c", in: container)?.boostedByName == "")
    }

    /// Rows with no payload are outside the predicate entirely, so they neither stall the pass nor
    /// get an answer invented for them.
    @Test("A row with no payload is left alone")
    func payloadlessRowIsUntouched() async throws {
        let (backfill, container) = try make([row(id: "d", payload: nil)])

        #expect(try await backfill.fillMissingBoostAttribution() == 0)
        #expect(try stored("d", in: container)?.boostedByName == nil)
    }
}
