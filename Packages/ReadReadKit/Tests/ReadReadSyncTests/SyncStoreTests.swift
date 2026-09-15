import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadSync

/// Merge policy tests. Every case here is one where getting it wrong loses a user's work silently:
/// a resurrected deletion, a discarded local edit, a reading position walking backwards.
@Suite("SyncStore")
struct SyncStoreTests {

    private func makeStore() throws -> (SyncStore, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        return (SyncStore(modelContainer: container), container)
    }

    private func page(_ records: [SyncRecord], maxRevision: Int? = nil, hasMore: Bool = false) -> SyncChangesPage {
        SyncChangesPage(
            records: records,
            maxRevision: maxRevision ?? (records.map(\.revision).max() ?? 0),
            hasMore: hasMore
        )
    }

    /// - Parameter writtenAt: Seconds from a fixed epoch, so records can be ordered explicitly.
    ///   Positions are merged on time, not on how far along they are.
    private func positionRecord(
        scope: String = "all",
        device: String,
        markMillis: Int64,
        writtenAt: TimeInterval,
        revision: Int
    ) throws -> SyncRecord {
        let payload = PositionPayload(
            scope: scope,
            deviceID: device,
            markSortKey: SortKey(millis: markMillis, id: "i").rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + writtenAt)
        )
        return SyncRecord(
            collection: .position,
            id: payload.recordID,
            revision: revision,
            deleted: false,
            updatedAt: revision * 1_000,
            payload: try SyncPayloadCoding.encodeToString(payload)
        )
    }

    // MARK: - Cursor

    @Test("The cursor starts at zero and advances with applied pages")
    func cursorAdvances() async throws {
        let (store, _) = try makeStore()

        #expect(try await store.pullCursor() == 0)

        try await store.apply(page([try positionRecord(device: "mac", markMillis: 1_000, writtenAt: 1, revision: 5)]))

        #expect(try await store.pullCursor() == 5)
    }

    /// A page arriving out of order, or a server replying oddly, must never move the cursor back —
    /// that would re-apply changes already superseded locally.
    @Test("The cursor never moves backwards")
    func cursorIsMonotonic() async throws {
        let (store, _) = try makeStore()

        try await store.apply(page([], maxRevision: 10))
        #expect(try await store.pullCursor() == 10)

        try await store.apply(page([], maxRevision: 3))
        #expect(try await store.pullCursor() == 10)
    }

    // MARK: - Positions

    @Test("A position from another device is applied")
    func appliesRemotePosition() async throws {
        let (store, container) = try makeStore()

        try await store.apply(page([
            try positionRecord(device: "iphone", markMillis: 5_000, writtenAt: 1, revision: 1),
        ]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        #expect(marks.count == 1)
        #expect(marks[0].deviceID == "iphone")
        #expect(marks[0].markSortKey.millis == 5_000)
    }

    /// The device's own row comes back on the next pull. Applying it must be a no-op, and must
    /// never overwrite a position that has since moved further ahead locally.
    @Test("A stale echo of our own position does not move it")
    func staleEchoDoesNotRegress() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)

        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 9_000, id: "i"),
            deviceID: "mac",
            in: context
        )
        try context.save()

        // The server still holds the value this device pushed earlier — older in time, which is
        // the only thing that decides it. That its position is also further back is incidental:
        // an echo carrying a further-*forward* position has to lose in exactly the same way.
        try await store.apply(page([
            try positionRecord(device: "mac", markMillis: 4_000, writtenAt: -3_600, revision: 2),
        ]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        #expect(marks.count == 1)
        #expect(marks[0].markSortKey.millis == 9_000)
    }

    /// The direction the previous design could not express. A device that scrolls back down writes
    /// a genuinely earlier position, and that report has to win because it is the more recent one.
    @Test("A later record moves the position backwards")
    func laterRecordMovesPositionBackwards() async throws {
        let (store, container) = try makeStore()

        try await store.apply(page([
            try positionRecord(device: "iphone", markMillis: 9_000, writtenAt: 10, revision: 1),
        ]))
        try await store.apply(page([
            try positionRecord(device: "iphone", markMillis: 2_000, writtenAt: 20, revision: 2),
        ]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        #expect(marks[0].markSortKey.millis == 2_000)
    }

    /// Records for one device can arrive out of order across pages; the older one must not undo
    /// the newer one already applied.
    @Test("An out-of-order record is discarded")
    func outOfOrderRecordIsDiscarded() async throws {
        let (store, container) = try makeStore()

        try await store.apply(page([
            try positionRecord(device: "iphone", markMillis: 2_000, writtenAt: 20, revision: 2),
        ]))
        try await store.apply(page([
            try positionRecord(device: "iphone", markMillis: 9_000, writtenAt: 10, revision: 3),
        ]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        #expect(marks[0].markSortKey.millis == 2_000)
    }

    /// The reduction orders positions on wall clock, so a device whose clock is badly wrong — one
    /// that lost its battery, say — would otherwise hold every scope's position until next used.
    @Test("An absurd future timestamp is clamped on the way in")
    func futureTimestampIsClamped() async throws {
        let (store, container) = try makeStore()

        let future = Date.now.addingTimeInterval(60 * 60 * 24 * 365)
        let payload = PositionPayload(
            scope: "all",
            deviceID: "broken-clock",
            markSortKey: SortKey(millis: 1_000, id: "i").rawValue,
            updatedAt: future
        )
        try await store.apply(page([SyncRecord(
            collection: .position,
            id: payload.recordID,
            revision: 1,
            deleted: false,
            updatedAt: 1_000,
            payload: try SyncPayloadCoding.encodeToString(payload)
        )]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        #expect(marks[0].updatedAt < future)
        #expect(marks[0].updatedAt <= Date.now.addingTimeInterval(60 * 60 + 5))
    }

    @Test("A position tombstone removes the row")
    func positionTombstoneDeletes() async throws {
        let (store, container) = try makeStore()

        try await store.apply(page([try positionRecord(device: "old", markMillis: 1_000, writtenAt: 1, revision: 1)]))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PositionMark>()) == 1)

        try await store.apply(page([
            SyncRecord(collection: .position, id: "all|old", revision: 2, deleted: true, updatedAt: 0, payload: ""),
        ]))

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PositionMark>()) == 0)
    }

    // MARK: - Local edits are protected

    /// The case that loses user work: an edit made locally but not yet pushed, and a pull that
    /// carries the server's older copy of the same record.
    @Test("A record with a queued local change is not overwritten by the server's older copy")
    func queuedLocalChangeWins() async throws {
        let (store, container) = try makeStore()

        // The user just marked this scope read to the end; it is queued, not yet pushed.
        let localPayload = PositionPayload(
            scope: "all",
            deviceID: "mac",
            markSortKey: SortKey(millis: 9_999, id: "i").rawValue,
            updatedAt: .now
        )
        try await store.enqueue(
            collection: .position,
            recordID: localPayload.recordID,
            payload: try SyncPayloadCoding.encodeToString(localPayload)
        )
        let context = ModelContext(container)
        try ThresholdService.setPosition(.all, to: SortKey(millis: 9_999, id: "i"), deviceID: "mac", in: context)
        try context.save()

        // A pull now delivers the server's older value for that same record.
        // Deliberately *newer* in time, so it would win the ordinary merge outright.
        try await store.apply(page([
            try positionRecord(device: "mac", markMillis: 100, writtenAt: 86_400, revision: 3),
        ]))

        let marks = try ModelContext(container).fetch(FetchDescriptor<PositionMark>())
        // Untouched, because the local edit has not been sent yet and would otherwise be silently
        // discarded by the server's own echo of an older state.
        #expect(marks[0].markSortKey.millis == 9_999)
        // The cursor still advances: the record was seen, just deliberately not applied.
        #expect(try await store.pullCursor() == 3)
    }

    // MARK: - Read Later

    @Test("A read-later entry is created and its deletion removes it")
    func readLaterRoundTrips() async throws {
        let (store, container) = try makeStore()
        let payload = ReadLaterPayload(ReadLaterEntry(
            itemID: "item-1",
            sourceID: "feed-1",
            accountID: UUID(),
            kind: .article,
            title: "Saved",
            sourceTitle: "Feed One",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: "item-1")
        ))

        try await store.apply(page([
            SyncRecord(
                collection: .readLater,
                id: "item-1",
                revision: 1,
                deleted: false,
                updatedAt: 1,
                payload: try SyncPayloadCoding.encodeToString(payload)
            ),
        ]))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ReadLaterEntry>()) == 1)

        try await store.apply(page([
            SyncRecord(collection: .readLater, id: "item-1", revision: 2, deleted: true, updatedAt: 2, payload: ""),
        ]))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ReadLaterEntry>()) == 0)
    }

    /// The read-later list is ordered by `addedAt`, so re-applying an unchanged entry must not
    /// touch it or the list would reshuffle on every sync.
    @Test("Re-applying an unchanged read-later entry changes nothing")
    func unchangedReadLaterIsNoOp() async throws {
        let (store, _) = try makeStore()
        let payload = ReadLaterPayload(ReadLaterEntry(
            itemID: "item-1",
            sourceID: "feed-1",
            accountID: UUID(),
            kind: .article,
            title: "Saved",
            sourceTitle: "Feed One",
            publishedAt: .now,
            sortKey: SortKey(millis: 1, id: "item-1")
        ))
        let record = SyncRecord(
            collection: .readLater,
            id: "item-1",
            revision: 1,
            deleted: false,
            updatedAt: 1,
            payload: try SyncPayloadCoding.encodeToString(payload)
        )

        #expect(try await store.apply(page([record])) == 1)
        #expect(try await store.apply(page([record], maxRevision: 1)) == 0)
    }

    // MARK: - Filters

    @Test("A newer filter edit wins and an older one is ignored")
    func filterLastWriterWins() async throws {
        let (store, container) = try makeStore()
        let id = UUID()

        func record(pattern: String, updatedAt: Date, revision: Int) throws -> SyncRecord {
            var payload = FilterPayload(FilterRule(id: id, pattern: pattern))
            payload.updatedAt = updatedAt
            return SyncRecord(
                collection: .filter,
                id: id.uuidString,
                revision: revision,
                deleted: false,
                updatedAt: revision,
                payload: try SyncPayloadCoding.encodeToString(payload)
            )
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.apply(page([try record(pattern: "first", updatedAt: base, revision: 1)]))
        try await store.apply(page([try record(pattern: "second", updatedAt: base.addingTimeInterval(60), revision: 2)]))
        // An older edit arriving late must not undo the newer one.
        try await store.apply(page([try record(pattern: "stale", updatedAt: base.addingTimeInterval(-60), revision: 3)]))

        let rules = try ModelContext(container).fetch(FetchDescriptor<FilterRule>())
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "second")
    }

    @Test("A filter with a non-UUID id is skipped without aborting the page")
    func malformedFilterIDIsSkipped() async throws {
        let (store, container) = try makeStore()

        let applied = try await store.apply(page([
            SyncRecord(collection: .filter, id: "not-a-uuid", revision: 1, deleted: false, updatedAt: 1, payload: "{}"),
            try positionRecord(device: "mac", markMillis: 1_000, writtenAt: 1, revision: 2),
        ]))

        // The valid record in the same page still lands: one bad payload from any device must not
        // wedge sync for all of them.
        #expect(applied == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PositionMark>()) == 1)
        #expect(try await store.pullCursor() == 2)
    }

    // MARK: - Accounts

    @Test("An account arrives without credentials")
    func accountCarriesNoSecrets() async throws {
        let (store, container) = try makeStore()
        let id = UUID()
        let payload = AccountPayload(AccountRecord(
            id: id,
            kind: .freshRSS,
            displayName: "rss.example.net",
            serverURLString: "https://rss.example.net",
            username: "matze"
        ))
        let encoded = try SyncPayloadCoding.encodeToString(payload)

        // The payload itself must not contain anything password-shaped.
        #expect(!encoded.lowercased().contains("password"))
        #expect(!encoded.lowercased().contains("token"))
        #expect(!encoded.lowercased().contains("secret"))

        try await store.apply(page([
            SyncRecord(collection: .account, id: id.uuidString, revision: 1, deleted: false, updatedAt: 1, payload: encoded),
        ]))

        let accounts = try ModelContext(container).fetch(FetchDescriptor<AccountRecord>())
        #expect(accounts.count == 1)
        #expect(accounts[0].username == "matze")
        #expect(accounts[0].serverURLString == "https://rss.example.net")
    }

    /// Builds an account tombstone the way `SyncOutbox.recordAccountDeletion` does: naming the
    /// account, not only the id it happened to carry on the device it was removed from.
    private func accountTombstone(
        id: UUID,
        server: String = "https://mastodon.social",
        username: String = "matze",
        kind: AccountKind = .mastodon,
        revision: Int = 2
    ) throws -> SyncRecord {
        let payload = AccountPayload(AccountRecord(
            id: id,
            kind: kind,
            displayName: "@\(username)@host",
            serverURLString: server,
            username: username
        ))
        return SyncRecord(
            collection: .account,
            id: id.uuidString,
            revision: revision,
            deleted: true,
            updatedAt: revision * 1_000,
            payload: try SyncPayloadCoding.encodeToString(payload)
        )
    }

    @Test("Removing an account reaches the device holding it under a different id")
    func accountDeletionMatchesOnIdentity() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        // The shape two devices end up in when each signed in for itself: the same account, a
        // different `UUID` on each. A tombstone matched only by id deleted nothing here, and the
        // account the reader removed on the Mac carried on refreshing on this device for ever.
        let local = AccountRecord(
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social/",
            username: "Matze"
        )
        context.insert(local)
        try context.save()

        try await store.apply(page([try accountTombstone(id: UUID())]))

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<AccountRecord>()) == 0)
    }

    @Test("Removing a differently-identified account is left alone")
    func accountDeletionDoesNotTakeNeighboursWithIt() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let other = AccountRecord(
            kind: .mastodon,
            displayName: "@someone@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "someone"
        )
        context.insert(other)
        try context.save()

        try await store.apply(page([try accountTombstone(id: UUID(), username: "matze")]))

        // Same instance, different account. Matching on the server alone would sign the reader out
        // of every account they hold on a busy instance.
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<AccountRecord>()) == 1)
        #expect(try after.fetch(FetchDescriptor<AccountRecord>())[0].username == "someone")
    }

    @Test("A local copy removed by identity is retracted from the server too")
    func aliasDeletionIsPushedOnward() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let local = AccountRecord(
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze"
        )
        context.insert(local)
        try context.save()

        try await store.apply(page([try accountTombstone(id: UUID())]))

        // The server still holds a live record under *this* device's id. Without retracting it, the
        // next device to sync from scratch picks the account up again from that record.
        let queued = try await store.pendingPushRecords()
        #expect(queued.count == 1)
        #expect(queued[0].collection == .account)
        #expect(queued[0].id == local.id.uuidString)
        #expect(queued[0].deleted)
        // And it names the account in turn, or it is the same message that reached nobody.
        #expect(queued[0].payload.contains("matze"))
        #expect(!queued[0].payload.lowercased().contains("token"))
    }

    @Test("A tombstone for an account already gone queues nothing")
    func deletionOfAnAbsentAccountIsInert() async throws {
        let (store, _) = try makeStore()

        try await store.apply(page([try accountTombstone(id: UUID())]))

        // What stops the devices trading retractions for ever: each one tombstones its own copy
        // once, and a tombstone that matches nothing is the end of the line.
        #expect(try await store.pendingPushRecords().isEmpty)
    }

    @Test("A tombstone with no payload still removes the account it names")
    func deletionFallsBackToTheIdAlone() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let id = UUID()
        context.insert(AccountRecord(
            id: id,
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze"
        ))
        try context.save()

        // What a server that predates payload-carrying tombstones delivers. Matching on the id is
        // then all there is, which is exactly the behaviour this replaced — no worse, so an app
        // updated before its server still removes accounts it can recognise.
        try await store.apply(page([
            SyncRecord(collection: .account, id: id.uuidString, revision: 2, deleted: true, updatedAt: 2, payload: ""),
        ]))

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<AccountRecord>()) == 0)
        #expect(try await store.pendingPushRecords().isEmpty)
    }

    @Test("A removed account takes its cached items with it")
    func deletionClearsWhatWasIngested() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let id = UUID()
        context.insert(AccountRecord(
            id: id,
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze"
        ))
        context.insert(CachedItem(
            id: "mastodon:\(id.uuidString):1",
            sourceID: "home",
            accountID: id,
            kind: .status,
            title: "A post",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_000, id: "1"),
            ingestKey: SortKey(millis: 1_000, id: "1")
        ))
        try context.save()

        let result = try await store.applyReportingCollections(page([try accountTombstone(id: id)]))

        // Items are namespaced by account id, so one left behind can never be refreshed, pruned or
        // opened again — it simply sits in the timeline belonging to nothing.
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<CachedItem>()) == 0)
        // And the caller is told which account it was, because the Keychain items keyed by that id
        // are the one thing this actor cannot clear itself.
        #expect(result.removedAccountIDs == [id])
    }

    // MARK: - Outbox

    @Test("Queued changes become push records")
    func outboxProducesPushRecords() async throws {
        let (store, _) = try makeStore()

        try await store.enqueue(collection: .position, recordID: "all|mac", payload: #"{"a":1}"#)
        try await store.enqueue(collection: .filter, recordID: "f1", payload: #"{"b":2}"#)

        let records = try await store.pendingPushRecords()
        #expect(records.count == 2)
        #expect(records.map(\.collection).contains(.position))
    }

    /// Only the final state is worth sending, so a second edit replaces the queued payload rather
    /// than queueing behind it.
    @Test("Re-queuing the same record replaces its payload")
    func requeueReplacesPayload() async throws {
        let (store, _) = try makeStore()

        try await store.enqueue(collection: .position, recordID: "all|mac", payload: #"{"v":1}"#)
        try await store.enqueue(collection: .position, recordID: "all|mac", payload: #"{"v":2}"#)

        let records = try await store.pendingPushRecords()
        #expect(records.count == 1)
        #expect(records[0].payload == #"{"v":2}"#)
    }

    @Test("A deletion queues as a tombstone with no payload")
    func deletionQueuesAsTombstone() async throws {
        let (store, _) = try makeStore()

        try await store.enqueueDeletion(collection: .filter, recordID: "f1")

        let records = try await store.pendingPushRecords()
        #expect(records[0].deleted)
        #expect(records[0].payload.isEmpty)
    }

    @Test("Accepted records leave the outbox")
    func acceptedRecordsAreCleared() async throws {
        let (store, _) = try makeStore()
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        let records = try await store.pendingPushRecords()
        try await store.clearPending(records)

        #expect(try await store.pendingPushRecords().isEmpty)
    }

    /// A malformed record will fail identically forever. Leaving it queued would block every later
    /// change behind it, so it is dropped.
    @Test("A permanently rejected record is dropped from the outbox")
    func permanentRejectionDropsRecord() async throws {
        let (store, _) = try makeStore()
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        let records = try await store.pendingPushRecords()
        try await store.failPending(records, permanent: true)

        #expect(try await store.pendingPushRecords().isEmpty)
    }

    @Test("A transient failure keeps the record but gives up after repeated attempts")
    func transientFailureEventuallyGivesUp() async throws {
        let (store, _) = try makeStore()
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        for _ in 0..<4 {
            let records = try await store.pendingPushRecords()
            try await store.failPending(records, permanent: false)
            #expect(!records.isEmpty)
        }

        // Fifth failure: retrying forever would be indistinguishable from being stuck.
        let records = try await store.pendingPushRecords()
        try await store.failPending(records, permanent: false)
        #expect(try await store.pendingPushRecords().isEmpty)
    }
}
