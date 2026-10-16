import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// One post fetched by two accounts, listed once where accounts are merged.
///
/// What is worth pinning is less the grouping than the two ways it can go wrong. Too eager, and a
/// post vanishes from a list it belongs in — an account's own timeline, or All Items once the copy
/// it was showing has gone. Too timid, and the post is listed twice, which is the bug. So most of
/// these change something about the winning copy and check the post is still listed exactly once.
@Suite("Duplicate election")
struct DuplicateElectionTests {

    private let accountA = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000A")!
    private let accountB = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000B")!
    private let postURI = "https://example.social/users/someone/statuses/1"

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func home(_ accountID: UUID) -> String {
        SourceIdentifier.mastodonHome(accountID: accountID)
    }

    @discardableResult
    private func insert(
        _ id: String,
        account: UUID,
        key: String?,
        millis: Int64 = 1_700_000_000_000,
        kind: ItemKind = .status,
        arrivedLate: Bool = false,
        isFilteredOut: Bool = false,
        in context: ModelContext
    ) -> CachedItem {
        let sortKey = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: home(account),
            accountID: account,
            kind: kind,
            title: id,
            authorHandle: "someone@example.social",
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: sortKey,
            ingestKey: sortKey,
            arrivedLate: arrivedLate,
            isFilteredOut: isFilteredOut,
            duplicateKey: key
        )
        context.insert(item)
        return item
    }

    private func listed(_ scope: ScopeID, in context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: scope)))
            .map(\.id)
            .sorted()
    }

    // MARK: - Listing once

    @Test("All Items lists a post two accounts fetched once, and each home timeline keeps its copy")
    func listedOnceWhereMerged() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)
        try context.save()

        #expect(try listed(.all, in: context).count == 1)
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 1)
        #expect(try listed(.mastodonHome(accountID: accountA), in: context) == ["a"])
        #expect(try listed(.mastodonHome(accountID: accountB), in: context) == ["b"])
    }

    @Test("The oldest copy wins, so a later boost does not lift the post above the reader again")
    func oldestCopyWins() throws {
        let context = try makeContext()
        insert("original", account: accountA, key: postURI, millis: 1_700_000_000_000, in: context)
        insert("boost", account: accountB, key: postURI, millis: 1_700_000_500_000, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["original"])
    }

    @Test("Copies with the same time still have one winner")
    func tieIsBroken() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["a"])
    }

    @Test("Rows without a key are never merged", arguments: [nil, ""] as [String?])
    func keylessRowsStandAlone(key: String?) throws {
        let context = try makeContext()
        insert("a", account: accountA, key: key, kind: .article, in: context)
        insert("b", account: accountB, key: key, kind: .article, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["a", "b"])
    }

    @Test("Different posts by the same person both stay")
    func differentPostsStay() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI + "0", in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["a", "b"])
    }

    // MARK: - Handing over

    @Test("Switching off the winning copy's account hands All Items to the other copy, and back")
    func accountSwitchHandsOver() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)

        try ThresholdService.setAccountEnabled(false, forAccountID: accountA, in: context)
        try context.save()
        #expect(try listed(.all, in: context) == ["b"])

        try ThresholdService.setAccountEnabled(true, forAccountID: accountA, in: context)
        try context.save()
        #expect(try listed(.all, in: context) == ["a"])
    }

    @Test("A copy a rule hides gives way to one in plain view, and Filtered Items does not list it")
    func filteredCopyGivesWay() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, isFilteredOut: true, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["b"])
        #expect(try listed(.filtered, in: context).isEmpty)
    }

    @Test("A post hidden in every copy is listed once in Filtered Items")
    func filteredEverywhereListedOnce() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, isFilteredOut: true, in: context)
        insert("b", account: accountB, key: postURI, isFilteredOut: true, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context).isEmpty)
        #expect(try listed(.filtered, in: context).count == 1)
        #expect(try ThresholdService.newerCount(for: .filtered, in: context) == 1)
    }

    @Test("A filter pass that hides the winning copy hands All Items over")
    func filterPassHandsOver() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)
        try context.save()
        #expect(try listed(.all, in: context) == ["a"])

        let rule = FilterRule(pattern: "a", fields: .title, scope: .account(accountA))
        let engine = FilterEngine([rule])
        try await FilterReevaluator(modelContainer: container).reapply(engine)

        #expect(try listed(.all, in: ModelContext(container)) == ["b"])
    }

    @Test("Removing the winning copy promotes the other")
    func removalPromotes() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)
        try context.save()

        let id = accountA
        try context.delete(model: CachedItem.self, where: #Predicate { $0.accountID == id })
        try context.save()
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.all, in: context) == ["b"])
    }

    @Test("Muting on one account hands its posts over to the other account's copies")
    func mutePromotes() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, in: context)
        try DuplicateElection.reelectAll(in: context)
        try context.save()

        try AuthorMute.removeItems(byAuthorHandle: "someone@example.social", accountID: accountA, in: context)
        try context.save()

        #expect(try listed(.all, in: context) == ["b"])
    }

    @Test("Older Items does not list a late copy of a post All Items already shows")
    func lateDuplicateIsNotListed() throws {
        let context = try makeContext()
        insert("a", account: accountA, key: postURI, in: context)
        insert("b", account: accountB, key: postURI, arrivedLate: true, in: context)
        try DuplicateElection.reelectAll(in: context)

        #expect(try listed(.lateArrivals, in: context).isEmpty)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 0)
        #expect(try ThresholdService.lateArrivalCount(for: .mastodonHome(accountID: accountB), in: context) == 1)
    }

    // MARK: - Ingest

    @Test("Ingest flags a second account's copy in the same save that writes it")
    func ingestElects() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        for account in [accountA, accountB] {
            let id = SourceIdentifier.mastodonItem(accountID: account, statusID: "1")
            let key = SortKey(millis: 1_700_000_000_000, id: id)
            _ = try await sink.commit(
                items: [IngestedItem(
                    id: id,
                    sourceID: home(account),
                    accountID: account,
                    kind: .status,
                    title: "A post.",
                    publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
                    sortKey: key,
                    ingestKey: key,
                    duplicateKey: postURI,
                    providerID: "1"
                )],
                accountID: account,
                streamKey: "home",
                resumeContinuation: "",
                pendingHighestSeenID: "1"
            )
        }

        let context = ModelContext(container)
        #expect(try listed(.all, in: context).count == 1)
        #expect(try listed(.mastodonHome(accountID: accountB), in: context).count == 1)
    }

    @Test("A re-ingest without a key keeps the one already stored")
    func reingestKeepsKey() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        insert("a", account: accountA, key: postURI, in: context)
        try context.save()

        let sink = SwiftDataIngestSink(modelContainer: container)
        let key = SortKey(millis: 1_700_000_000_000, id: "a")
        _ = try await sink.commit(
            items: [IngestedItem(
                id: "a",
                sourceID: home(accountA),
                accountID: accountA,
                kind: .status,
                title: "Edited.",
                publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
                sortKey: key,
                ingestKey: key,
                providerID: "a"
            )],
            accountID: accountA,
            streamKey: "home",
            resumeContinuation: "",
            pendingHighestSeenID: "a"
        )

        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == "a" })
        descriptor.fetchLimit = 1
        #expect(try ModelContext(container).fetch(descriptor).first?.duplicateKey == postURI)
    }

    @Test("Re-electing a large set of keys works across fetch chunks")
    func manyKeys() throws {
        let context = try makeContext()
        for index in 0..<1_200 {
            insert("a\(index)", account: accountA, key: "\(postURI)/\(index)", in: context)
            insert("b\(index)", account: accountB, key: "\(postURI)/\(index)", in: context)
        }
        try context.save()

        let changed = try DuplicateElection.reelect(
            keys: (0..<1_200).map { "\(postURI)/\($0)" },
            in: context
        )

        #expect(changed == 1_200)
        #expect(try listed(.all, in: context).count == 1_200)
    }
}
