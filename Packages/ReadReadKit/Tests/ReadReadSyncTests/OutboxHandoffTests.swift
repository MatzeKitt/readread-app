import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadSync

/// The handoff between the two halves of the outbox.
///
/// `SyncOutbox` queues a change on whichever context made it — in the app, the **main** context —
/// while `SyncStore` drains the queue from its own `@ModelActor` context. Every existing sync test
/// enqueues through `SyncStore` itself, so all of them stay on one context and none of them
/// exercises the crossing. That is precisely where a queued position went missing in the running
/// app: pulls happened, the row sat in the store, and nothing was ever pushed.
@Suite("Outbox handoff")
struct OutboxHandoffTests {

    @Test("A change queued on the main context is visible to the sync store")
    func mainContextChangeReachesTheStore() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)

        // Built before the change is made, as it is in the app: `RefreshEngine` creates the store
        // once at launch and keeps it for the process's lifetime.
        #expect(try await store.pendingPushRecords().isEmpty)

        let context = ModelContext(container)
        let mark = try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "feed/1#1"),
            deviceID: "device-a",
            in: context
        )
        try SyncOutbox.record(mark, in: context)
        try context.save()

        let pending = try await store.pendingPushRecords()
        #expect(pending.count == 1)
        #expect(pending.first?.collection == .position)
    }

    @Test("Clearing from the store removes what the main context queued")
    func clearingCrossesBack() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)

        let context = ModelContext(container)
        let mark = try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "feed/1#1"),
            deviceID: "device-a",
            in: context
        )
        try SyncOutbox.record(mark, in: context)
        try context.save()

        let pending = try await store.pendingPushRecords()
        try await store.clearPending(pending)

        // The other direction of the same crossing. Left un-cleared, every sync would re-push the
        // same record forever.
        #expect(try await store.pendingPushRecords().isEmpty)
    }
}
