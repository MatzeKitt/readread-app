import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// A reply subscription's list is a slice of its account's home timeline, selected by a column on
/// the item. These pin the three things that follow from that: the slice is exactly the marked
/// rows, a position moves between it and the home timeline the way it moves between a feed and its
/// folder, and nothing but removing the subscription takes a row out of it.
@Suite("Reply subscriptions")
struct ReplySubscriptionTests {

    private let accountID = UUID()
    private let device = "device-a"

    private var homeID: String { SourceIdentifier.mastodonHome(accountID: accountID) }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func makeSubscription(in context: ModelContext) -> ReplySubscription {
        let subscription = ReplySubscription(
            accountID: accountID,
            statusID: "100",
            statusURLString: "https://mastodon.social/@matze/100",
            title: "Release thread"
        )
        context.insert(subscription)
        return subscription
    }

    /// Statuses in the home timeline, oldest first, one second apart. Those named in `followed` are
    /// marked as replies in the subscription.
    @discardableResult
    private func insertStatuses(
        count: Int,
        followed: Set<Int> = [],
        subscription: ReplySubscription? = nil,
        in context: ModelContext
    ) -> [SortKey] {
        context.insert(CachedSource(id: homeID, accountID: accountID, kind: .status, title: "Home"))
        return (0..<count).map { offset in
            let millis = 1_700_000_000_000 + Int64(offset) * 1_000
            let id = SourceIdentifier.mastodonItem(accountID: accountID, statusID: "\(offset)")
            let key = SortKey(millis: millis, id: id)
            context.insert(CachedItem(
                id: id,
                sourceID: homeID,
                accountID: accountID,
                kind: .status,
                title: "Post \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key,
                replySubscriptionID: followed.contains(offset) ? subscription?.id : nil
            ))
            return key
        }
    }

    private func count(_ scope: ScopeID, in context: ModelContext) throws -> Int {
        try ThresholdService.newerCount(for: scope, in: context)
    }

    // MARK: - What the list holds

    @Test("The list holds exactly the replies marked with the subscription")
    func listHoldsMarkedReplies() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        let other = ReplySubscription(accountID: accountID, statusID: "999", statusURLString: "", title: "")
        context.insert(other)
        insertStatuses(count: 5, followed: [1, 3], subscription: subscription, in: context)
        try context.save()

        let listed = try context.fetch(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: subscription.scope)
        ))
        #expect(Set(listed.map(\.title)) == ["Post 1", "Post 3"])
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: other.scope)
        )) == 0)

        // Still in the home timeline as well: the subscription is a slice of it, not a move.
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: .mastodonHome(accountID: accountID))
        )) == 5)
    }

    @Test("A filtered reply is missing from the list and from its count")
    func filteredReplyIsHidden() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        insertStatuses(count: 3, followed: [0, 1, 2], subscription: subscription, in: context)
        let hidden = try context.fetch(FetchDescriptor<CachedItem>()).first { $0.title == "Post 2" }
        hidden?.isFilteredOut = true
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: subscription.scope)
        )) == 2)
        #expect(try count(subscription.scope, in: context) == 2)
    }

    // MARK: - Positions

    @Test("Reading the home timeline carries the subscription with it")
    func homeCarriesSubscription() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        let keys = insertStatuses(count: 6, followed: [1, 4, 5], subscription: subscription, in: context)
        try context.save()

        #expect(try count(subscription.scope, in: context) == 3)

        try ThresholdService.setPositionCascading(
            .mastodonHome(accountID: accountID),
            to: keys[3],
            deviceID: device,
            in: context
        )

        // Items 4 and 5 sit above the fold the home timeline was read to; item 1 is below it.
        #expect(try count(subscription.scope, in: context) == 2)
    }

    @Test("Reading back down a subscription lowers the home timeline to match")
    func subscriptionLowersHome() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        let keys = insertStatuses(count: 6, followed: [1, 4], subscription: subscription, in: context)
        try ThresholdService.setPositionCascading(.all, to: keys[5], deviceID: device, in: context)
        try context.save()
        #expect(try count(.mastodonHome(accountID: accountID), in: context) == 0)

        try ThresholdService.setPositionCascading(subscription.scope, to: keys[1], deviceID: device, in: context)

        // The subscription now counts item 4 above its fold, so the home timeline it is inside
        // cannot claim to be read past it.
        #expect(try count(subscription.scope, in: context) == 1)
        #expect(try count(.mastodonHome(accountID: accountID), in: context) >= 1)
        #expect(try count(.all, in: context) >= 1)
    }

    @Test("A subscription is inside its home timeline and inside All Items")
    func containment() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        insertStatuses(count: 1, in: context)
        try context.save()

        #expect(try ThresholdService.containedScopes(of: .all, in: context).contains(subscription.scope))
        #expect(try ThresholdService.containedScopes(of: .mastodonHome(accountID: accountID), in: context) == [subscription.scope])
        #expect(try ThresholdService.enclosingScopes(of: subscription.scope, in: context) == [
            .all, .mastodonHome(accountID: accountID),
        ])
    }

    @Test("The containment repair raises a subscription to its home timeline")
    func repairRaisesSubscription() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        let keys = insertStatuses(count: 4, followed: [0, 1, 2, 3], subscription: subscription, in: context)
        try ThresholdService.setPosition(.mastodonHome(accountID: accountID), to: keys[3], deviceID: device, in: context)
        try context.save()

        let repaired = try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)

        #expect(repaired.contains { $0.scopeRaw == subscription.scope.rawValue })
        #expect(try count(subscription.scope, in: context) == 0)
    }

    // MARK: - Ingest

    private func ingestedReply(subscription: UUID?) -> IngestedItem {
        let itemID = SourceIdentifier.mastodonItem(accountID: accountID, statusID: "201")
        let key = SortKey(millis: 1_700_000_000_000, id: itemID)
        return IngestedItem(
            id: itemID,
            sourceID: homeID,
            accountID: accountID,
            kind: .status,
            title: "A reply",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key,
            replySubscriptionID: subscription,
            providerID: "201"
        )
    }

    /// Commits one reply through the real sink, once per stream given, in order.
    private func ingest(
        _ arrivals: [(streamKey: String, subscription: UUID?)],
        into container: ModelContainer
    ) async throws -> [CachedItem] {
        let sink = SwiftDataIngestSink(modelContainer: container)
        for arrival in arrivals {
            try await sink.commit(
                items: [ingestedReply(subscription: arrival.subscription)],
                accountID: accountID,
                streamKey: arrival.streamKey,
                resumeContinuation: "",
                pendingHighestSeenID: ""
            )
        }
        return try ModelContext(container).fetch(FetchDescriptor<CachedItem>())
    }

    @Test("The home walk seeing a followed reply again leaves it in the subscription")
    func homeWalkKeepsMark() async throws {
        let subscriptionID = UUID()
        let stored = try await ingest([
            (ReplySubscription.streamKey(for: subscriptionID), subscriptionID),
            ("home", nil),
        ], into: try ReadReadStore.inMemoryContainer())

        #expect(stored.count == 1)
        #expect(stored.first?.replySubscriptionID == subscriptionID)
    }

    @Test("A reply that arrived through the home timeline first joins the subscription")
    func subscriptionWalkMarksExistingRow() async throws {
        let subscriptionID = UUID()
        let stored = try await ingest([
            ("home", nil),
            (ReplySubscription.streamKey(for: subscriptionID), subscriptionID),
        ], into: try ReadReadStore.inMemoryContainer())

        #expect(stored.count == 1)
        #expect(stored.first?.replySubscriptionID == subscriptionID)
    }

    // MARK: - Removing

    @Test("Removing a subscription keeps its replies in the home timeline and forgets its walk")
    func removal() throws {
        let context = try makeContext()
        let subscription = makeSubscription(in: context)
        insertStatuses(count: 3, followed: [0, 2], subscription: subscription, in: context)
        context.insert(SyncCursor(accountID: accountID, streamKey: subscription.streamKey))
        context.insert(SyncCursor(accountID: accountID, streamKey: "home"))
        try context.save()

        try ReplySubscription.remove(subscription, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ReplySubscription>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>()) == 3)
        #expect(try context.fetch(FetchDescriptor<CachedItem>()).allSatisfy { $0.replySubscriptionID == nil })
        #expect(try context.fetch(FetchDescriptor<SyncCursor>()).map(\.streamKey) == ["home"])
    }
}
