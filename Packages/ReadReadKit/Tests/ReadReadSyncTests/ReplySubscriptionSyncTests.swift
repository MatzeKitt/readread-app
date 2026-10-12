import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// A reply subscription made on one device has to turn up on the others, follow the reader's last
/// edit, and take its list with it when it is removed.
@Suite("Reply subscription sync")
struct ReplySubscriptionSyncTests {

    private let accountID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    private let subscriptionID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!

    private func makeStore() throws -> (SyncStore, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        return (SyncStore(modelContainer: container), container)
    }

    private func record(
        statusID: String = "100",
        title: String = "Release thread",
        updatedAt: TimeInterval = 10,
        deleted: Bool = false,
        revision: Int = 1
    ) throws -> SyncRecord {
        let payload = ReplySubscriptionPayload(
            id: subscriptionID.uuidString,
            accountID: accountID.uuidString,
            statusID: statusID,
            statusURLString: "https://mastodon.social/@matze/\(statusID)",
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + updatedAt)
        )
        return SyncRecord(
            collection: .replySubscription,
            id: subscriptionID.uuidString,
            revision: revision,
            deleted: deleted,
            updatedAt: revision,
            payload: deleted ? "" : try SyncPayloadCoding.encodeToString(payload)
        )
    }

    private func page(_ records: [SyncRecord]) -> SyncChangesPage {
        SyncChangesPage(records: records, maxRevision: records.map(\.revision).max() ?? 0, hasMore: false)
    }

    /// One reply in the account's home timeline, marked with the subscription.
    private func insertFollowedReply(in context: ModelContext) {
        let id = SourceIdentifier.mastodonItem(accountID: accountID, statusID: "201")
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        context.insert(CachedItem(
            id: id,
            sourceID: SourceIdentifier.mastodonHome(accountID: accountID),
            accountID: accountID,
            kind: .status,
            title: "A reply",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            replySubscriptionID: subscriptionID
        ))
    }

    // MARK: - Applying

    @Test("A subscription made on another device appears here")
    func appliesNewSubscription() async throws {
        let (store, container) = try makeStore()

        let result = try await store.applyReportingCollections(page([try record()]))

        #expect(result.collections == [.replySubscription])
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<ReplySubscription>()).first)
        #expect(stored.id == subscriptionID)
        #expect(stored.accountID == accountID)
        #expect(stored.statusID == "100")
        #expect(stored.title == "Release thread")
    }

    @Test("A newer edit wins and an older one is ignored")
    func lastWriterWins() async throws {
        let (store, container) = try makeStore()
        try await store.apply(page([try record(title: "First", updatedAt: 10, revision: 1)]))

        try await store.apply(page([try record(title: "Renamed", updatedAt: 20, revision: 2)]))
        try await store.apply(page([try record(title: "Stale", updatedAt: 15, revision: 3)]))

        let stored = try ModelContext(container).fetch(FetchDescriptor<ReplySubscription>())
        #expect(stored.map(\.title) == ["Renamed"])
    }

    @Test("Pointing a subscription at another post lets go of the old post's replies")
    func repointForgetsConversation() async throws {
        let (store, container) = try makeStore()
        try await store.apply(page([try record(statusID: "100", updatedAt: 10, revision: 1)]))
        let context = ModelContext(container)
        insertFollowedReply(in: context)
        context.insert(SyncCursor(accountID: accountID, streamKey: ReplySubscription.streamKey(for: subscriptionID)))
        try context.save()

        try await store.apply(page([try record(statusID: "300", updatedAt: 20, revision: 2)]))

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<ReplySubscription>()).first?.statusID == "300")
        #expect(try fresh.fetch(FetchDescriptor<CachedItem>()).first?.replySubscriptionID == nil)
        #expect(try fresh.fetchCount(FetchDescriptor<SyncCursor>()) == 0)
    }

    @Test("A rename keeps the replies already in the list")
    func renameKeepsConversation() async throws {
        let (store, container) = try makeStore()
        try await store.apply(page([try record(title: "First", updatedAt: 10, revision: 1)]))
        let context = ModelContext(container)
        insertFollowedReply(in: context)
        try context.save()

        try await store.apply(page([try record(title: "Renamed", updatedAt: 20, revision: 2)]))

        #expect(try ModelContext(container).fetch(FetchDescriptor<CachedItem>()).first?.replySubscriptionID == subscriptionID)
    }

    @Test("A removal on another device removes the subscription and releases its replies")
    func tombstoneRemoves() async throws {
        let (store, container) = try makeStore()
        try await store.apply(page([try record(revision: 1)]))
        let context = ModelContext(container)
        insertFollowedReply(in: context)
        try context.save()

        try await store.apply(page([try record(deleted: true, revision: 2)]))

        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<ReplySubscription>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<CachedItem>()) == 1)
        #expect(try fresh.fetch(FetchDescriptor<CachedItem>()).first?.replySubscriptionID == nil)
    }

    // MARK: - Editing here

    @Test("Subscribing queues the subscription for the other devices")
    func subscribingQueuesRecord() throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)

        let subscription = try ReplySubscriptionEditing.subscribe(
            to: .init(accountID: accountID, statusID: "100", statusURLString: "https://mastodon.social/@matze/100"),
            title: "  Release thread ",
            in: context
        )
        try context.save()

        #expect(subscription.title == "Release thread")
        let queued = try context.fetch(FetchDescriptor<PendingChange>())
        #expect(queued.map(\.collection) == [.replySubscription])
        #expect(queued.first?.recordID == subscription.id.uuidString)
        #expect(queued.first?.isDeletion == false)
    }

    @Test("Subscribing twice to the same post gives back the one subscription")
    func subscribingTwiceIsOneSubscription() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let target = ReplySubscriptionEditing.Target(accountID: accountID, statusID: "100", statusURLString: "")

        let first = try ReplySubscriptionEditing.subscribe(to: target, title: "One", in: context)
        let second = try ReplySubscriptionEditing.subscribe(to: target, title: "Two", in: context)
        try context.save()

        #expect(first.id == second.id)
        #expect(try context.fetchCount(FetchDescriptor<ReplySubscription>()) == 1)
    }

    @Test("Unsubscribing queues a tombstone")
    func unsubscribingQueuesTombstone() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let subscription = try ReplySubscriptionEditing.subscribe(
            to: .init(accountID: accountID, statusID: "100", statusURLString: ""),
            title: "One",
            in: context
        )
        try context.save()

        try ReplySubscriptionEditing.unsubscribe(subscription, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ReplySubscription>()) == 0)
        let queued = try context.fetch(FetchDescriptor<PendingChange>())
        #expect(queued.count == 1)
        #expect(queued.first?.isDeletion == true)
    }

    @Test("A suggested title names the author and the start of the post")
    func suggestedTitle() {
        #expect(ReplySubscriptionEditing.suggestedTitle(authorName: "Matze", text: "New  release\nout now") == "Matze: New release out now")
        #expect(ReplySubscriptionEditing.suggestedTitle(authorName: "Matze", text: "  ") == "Matze")

        let long = ReplySubscriptionEditing.suggestedTitle(authorName: "", text: String(repeating: "word ", count: 40))
        #expect(long.hasSuffix("…"))
        #expect(long.count <= 61)
    }

    // MARK: - Pushing

    /// The reason pushes are split by collection. A server not yet updated for subscriptions
    /// rejects the record outright, and a rejected push is dropped — which, in one shared batch,
    /// dropped every reading position queued beside it.
    @Test("A collection the server refuses does not take the others down with it")
    func refusedCollectionIsIsolated() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)
        let transport = StubTransport([
            .json(#"{"records":[],"maxRevision":0,"hasMore":false}"#),
            .json(#"{"applied":[{"collection":"position","id":"all|mac","revision":1}],"maxRevision":1}"#),
            .status(400, body: #"{"error":"bad_request","message":"Unknown collection"}"#),
        ])
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: "https://sync.example.net")!, token: "t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        let coordinator = SyncCoordinator(client: client, store: store)

        try await store.enqueue(collection: .replySubscription, recordID: subscriptionID.uuidString, payload: "{}")
        try await store.enqueue(collection: .position, recordID: "all|mac", payload: "{}")

        await #expect(throws: SyncError.rejected("Unknown collection")) {
            _ = try await coordinator.sync()
        }

        // The position went out in a request of its own and was accepted; only the subscription
        // was refused, and dropped.
        #expect(await transport.requestCount == 3)
        #expect(try await store.pendingPushRecords().isEmpty)
        let positionPush = await transport.body(at: 1)
        #expect(positionPush.contains(#""collection":"position""#))
        #expect(!positionPush.contains("replySubscription"))
        #expect(await transport.body(at: 2).contains("replySubscription"))
    }
}
