import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import MastodonAPI

/// The two passes added with link previews and with Like state.
///
/// Same hazard as the rest of the backfill: each is a loop over a predicate the loop itself has to
/// falsify, and getting that wrong does not fail loudly — it decodes the same two hundred rows on
/// every launch, for ever, in a build that otherwise looks fine.
@Suite("Status backfill: cards and Like state")
struct StatusBackfillCardTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!

    private func payload(
        card: String = "null",
        favourited: String = "null",
        reblogged: String = "null"
    ) -> Data {
        Data("""
        {
            "id": "2001",
            "uri": "https://other.example/users/orig/statuses/2001",
            "created_at": "2026-01-01T00:00:00.000Z",
            "content": "<p>Look at this.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://other.example/@orig/2001", "poll": null,
            "card": \(card),
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 1, "reblogs_count": 2, "favourites_count": 3,
            "favourited": \(favourited), "reblogged": \(reblogged),
            "edited_at": null, "language": "en",
            "account": {
                "id": "3", "username": "orig", "acct": "orig@other.example",
                "display_name": "Original Author",
                "avatar": "https://files.example/o.png", "avatar_static": null,
                "url": "https://other.example/@orig", "bot": false, "emojis": []
            }
        }
        """.utf8)
    }

    private static let fullCard = """
    {
        "url": "https://www.example.com/a-piece",
        "title": "A headline",
        "description": "A blurb.",
        "type": "link",
        "image": "https://cdn.example.com/og.png",
        "provider_name": ""
    }
    """

    /// What an instance produces for a link whose target answered with nothing usable.
    private static let emptyCard = """
    {"url": "https://www.example.com/x", "title": "", "description": "", "type": "link", "image": null}
    """

    private func row(id: String, payload: Data?) -> CachedItem {
        CachedItem(
            id: id,
            sourceID: "mastodon:\(accountID):home",
            accountID: accountID,
            kind: .status,
            title: "Look at this.",
            excerpt: "Look at this.",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: id),
            ingestKey: SortKey(millis: 1_700_000_000_000, id: id),
            mastodonPayload: payload
        )
    }

    private func make(_ rows: [CachedItem]) throws -> (StatusBackfill, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        for row in rows {
            context.insert(row)
            // Undo what the initialiser wrote. The insert path records a status with no card as
            // *examined*, which is right for a fresh ingest and is exactly what these passes are
            // meant not to find — so the rows have to be put back into the state a store written
            // before the columns existed would actually be in.
            row.cardURLString = nil
            row.isFavourited = nil
            row.isReblogged = nil
        }
        try context.save()
        return (StatusBackfill(modelContainer: container), container)
    }

    private func stored(_ id: String, in container: ModelContainer) throws -> CachedItem? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Link previews

    @Test("A post already in the store gains its link preview")
    func cardIsBackfilled() async throws {
        let (backfill, container) = try make([row(id: "a", payload: payload(card: Self.fullCard))])

        #expect(try await backfill.fillMissingLinkCards() == 1)

        let card = try #require(try stored("a", in: container)?.linkCard)
        #expect(card.title == "A headline")
        #expect(card.summary == "A blurb.")
        #expect(card.hostLabel == "example.com")
        #expect(card.imageURL?.absoluteString == "https://cdn.example.com/og.png")
    }

    /// Most posts link to nothing, so "examined, no card" has to be a stored answer.
    @Test("A post with no link is recorded as answered")
    func cardlessPostIsAnswered() async throws {
        let (backfill, container) = try make([row(id: "b", payload: payload())])

        // Not counted — nothing was recovered — but written all the same.
        #expect(try await backfill.fillMissingLinkCards() == 0)
        #expect(try stored("b", in: container)?.cardURLString == "")
    }

    /// An instance will hand over a card with empty strings in it. Storing one would put an empty
    /// box under the post.
    @Test("A card with no headline is answered as no card")
    func emptyCardIsNoCard() async throws {
        let (backfill, container) = try make([row(id: "c", payload: payload(card: Self.emptyCard))])

        #expect(try await backfill.fillMissingLinkCards() == 0)
        #expect(try stored("c", in: container)?.cardURLString == "")
        #expect(try stored("c", in: container)?.linkCard == nil)
    }

    @Test("A second pass over link previews finds nothing left to do")
    func cardSecondPassIsEmpty() async throws {
        let (backfill, _) = try make([
            row(id: "a", payload: payload(card: Self.fullCard)),
            row(id: "b", payload: payload()),
            row(id: "c", payload: Data("{ not json".utf8)),
        ])

        _ = try await backfill.fillMissingLinkCards()

        #expect(try await backfill.fillMissingLinkCards() == 0)
    }

    // MARK: - Like and Boost state

    @Test("A post the reader had already favourited says so")
    func favouritedIsBackfilled() async throws {
        let (backfill, container) = try make([
            row(id: "a", payload: payload(favourited: "true", reblogged: "true")),
        ])

        #expect(try await backfill.fillMissingInteractionState() == 1)

        let stored = try #require(try stored("a", in: container))
        #expect(stored.isFavourited == true)
        #expect(stored.isReblogged == true)
    }

    /// The default that matters. `false` offers Like on a post that may already be liked, which the
    /// server absorbs as a no-op; `true` would offer Unlike on one that is not and quietly do
    /// nothing at all.
    @Test("A field the payload never carried is answered false, not left open")
    func absentFlagsBecomeFalse() async throws {
        let (backfill, container) = try make([row(id: "b", payload: payload())])

        #expect(try await backfill.fillMissingInteractionState() == 1)

        let stored = try #require(try stored("b", in: container))
        #expect(stored.isFavourited == false)
        #expect(stored.isReblogged == false)
    }

    @Test("An undecodable payload is answered rather than retried")
    func undecodableIsAnswered() async throws {
        let (backfill, container) = try make([row(id: "c", payload: Data("{ not json".utf8))])

        _ = try await backfill.fillMissingInteractionState()

        #expect(try stored("c", in: container)?.isFavourited == false)
        #expect(try await backfill.fillMissingInteractionState() == 0)
    }

    @Test("A second pass over Like state finds nothing left to do")
    func interactionSecondPassIsEmpty() async throws {
        let (backfill, _) = try make([
            row(id: "a", payload: payload(favourited: "true")),
            row(id: "b", payload: payload()),
        ])

        _ = try await backfill.fillMissingInteractionState()

        #expect(try await backfill.fillMissingInteractionState() == 0)
    }

    /// An article has no notion of either, and must stay out of a search that only wants statuses.
    @Test("Articles are left alone")
    func articlesAreLeftAlone() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let key = SortKey(millis: 1_700_000_000_000, id: "art")
        context.insert(CachedItem(
            id: "art",
            sourceID: "freshrss:\(accountID):feed/1",
            accountID: accountID,
            kind: .article,
            title: "An article",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key
        ))
        try context.save()

        let backfill = StatusBackfill(modelContainer: container)

        #expect(try await backfill.fillMissingLinkCards() == 0)
        #expect(try await backfill.fillMissingInteractionState() == 0)
        #expect(try stored("art", in: container)?.cardURLString == nil)
        #expect(try stored("art", in: container)?.isFavourited == nil)
    }
}
