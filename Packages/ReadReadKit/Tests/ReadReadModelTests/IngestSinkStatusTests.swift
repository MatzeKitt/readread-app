import Foundation
import ReadReadModel
import SwiftData
import Testing

/// How the store records the status-only columns.
///
/// The counts and the boost attribution are denormalised out of the stored payload so that a
/// timeline row never has to decode a status to draw itself. That only holds if the sink actually
/// writes them — on the insert *and* on the re-ingest an edited post produces.
@Suite("Ingest sink status columns")
struct IngestSinkStatusTests {

    private let accountID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
    private let streamKey = "home"

    private func item(
        id: String,
        engagement: StatusEngagement?,
        linkCard: LinkCard? = nil
    ) -> IngestedItem {
        IngestedItem(
            id: id,
            sourceID: "mastodon:\(accountID):home",
            accountID: accountID,
            kind: .status,
            title: "A post.",
            excerpt: "A post.",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: id),
            ingestKey: SortKey(millis: 1_700_000_000_000, id: id),
            linkCard: linkCard,
            engagement: engagement,
            providerID: id
        )
    }

    private let card = LinkCard(
        urlString: "https://www.example.com/a-piece",
        title: "A headline",
        summary: "A blurb.",
        imageURLString: "https://cdn.example.com/og.png"
    )

    private func commit(_ items: [IngestedItem], to sink: SwiftDataIngestSink) async throws {
        _ = try await sink.commit(
            items: items,
            accountID: accountID,
            streamKey: streamKey,
            resumeContinuation: "",
            pendingHighestSeenID: items.last?.providerID ?? ""
        )
    }

    private func stored(_ id: String, in container: ModelContainer) throws -> CachedItem? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @Test("A boost stores the booster's name")
    func boosterIsStored() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "a", engagement: StatusEngagement(boostedByName: "Marie Curie"))], to: sink)

        #expect(try stored("a", in: container)?.boostedByName == "Marie Curie")
    }

    /// Empty rather than nil, because nil means *not yet known* and is what `StatusBackfill`
    /// searches for. A freshly ingested post is known — it is simply not a boost — and leaving it
    /// nil would put every new post into a backfill pass that has nothing to recover.
    @Test("A post that is not a boost stores an answer, not an absence")
    func directPostStoresAnAnswer() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "b", engagement: StatusEngagement())], to: sink)

        #expect(try stored("b", in: container)?.boostedByName == "")
    }

    /// An edited post is re-ingested over its own row, which is the path that has to fill the
    /// column for anything already in the store.
    @Test("Re-ingesting a row fills in the attribution")
    func reingestFillsTheColumn() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        // As an older build would have written it: no engagement recorded at all.
        try await commit([item(id: "c", engagement: nil)], to: sink)
        #expect(try stored("c", in: container)?.boostedByName == nil)

        try await commit([item(id: "c", engagement: StatusEngagement(boostedByName: "Ada Lovelace"))], to: sink)

        #expect(try stored("c", in: container)?.boostedByName == "Ada Lovelace")
    }

    /// An article has no such notion, and inventing an empty answer for one would put it in the
    /// backfill's way.
    @Test("An article records nothing")
    func articleRecordsNothing() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        var article = item(id: "d", engagement: nil)
        article.kind = .article

        try await commit([article], to: sink)

        #expect(try stored("d", in: container)?.boostedByName == nil)
    }

    // MARK: - Link previews

    @Test("A post's link preview is stored as columns")
    func cardIsStored() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "e", engagement: StatusEngagement(), linkCard: card)], to: sink)

        #expect(try stored("e", in: container)?.linkCard == card)
    }

    /// Most posts link to nothing, so "examined, no card" has to be a stored answer — otherwise
    /// the backfill re-decodes every cardless post on every launch.
    @Test("A post with no link is stored as examined")
    func cardlessPostIsExamined() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "f", engagement: StatusEngagement())], to: sink)

        #expect(try stored("f", in: container)?.cardURLString == "")
    }

    /// An instance often resolves a card minutes after the post arrived, so the re-ingest is where
    /// one first appears.
    @Test("A card that appears later is picked up on the next ingest")
    func cardAppearsOnReingest() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "g", engagement: StatusEngagement())], to: sink)
        try await commit([item(id: "g", engagement: StatusEngagement(), linkCard: card)], to: sink)

        #expect(try stored("g", in: container)?.linkCard == card)
    }

    @Test("An article gets no card column at all")
    func articleHasNoCardColumn() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        var article = item(id: "h", engagement: nil)
        article.kind = .article

        try await commit([article], to: sink)

        #expect(try stored("h", in: container)?.cardURLString == nil)
    }

    // MARK: - Like and Boost state

    @Test("The reader's own state is stored")
    func interactionStateIsStored() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit(
            [item(id: "i", engagement: StatusEngagement(isFavourited: true, isReblogged: false))],
            to: sink
        )

        #expect(try stored("i", in: container)?.isFavourited == true)
        #expect(try stored("i", in: container)?.isReblogged == false)
    }

    /// Unlike the counts, which are refreshed unconditionally. A missing answer is not the same as
    /// "no longer favourited", and overwriting a known `true` with nil would make a post the reader
    /// has liked offer Like again after every refresh.
    @Test("A refresh that omits the state does not erase it")
    func omittedStateIsNotErased() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "j", engagement: StatusEngagement(isFavourited: true))], to: sink)
        try await commit(
            [item(id: "j", engagement: StatusEngagement(favouriteCount: 12, isFavourited: nil))],
            to: sink
        )

        let row = try #require(try stored("j", in: container))
        // The count is a live property of the post and is taken as given.
        #expect(row.favouriteCount == 12)
        // The flag is not, and the previous answer stands.
        #expect(row.isFavourited == true)
    }

    /// The other direction has to work too: unliking from another client shows up as `false`, and
    /// that is an answer, not an absence.
    @Test("A refresh that says false is believed")
    func falseIsAnAnswer() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        try await commit([item(id: "k", engagement: StatusEngagement(isFavourited: true))], to: sink)
        try await commit([item(id: "k", engagement: StatusEngagement(isFavourited: false))], to: sink)

        #expect(try stored("k", in: container)?.isFavourited == false)
    }
}
