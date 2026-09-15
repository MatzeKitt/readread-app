import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadSync

/// The outbox is the only thing that turns a local edit into something another device will ever
/// see, and nothing else in the app notices when it does not — a position simply stays put. So its
/// behaviour is pinned here rather than left to the end-to-end tests.
@Suite("SyncOutbox")
struct SyncOutboxTests {

    private let accountID = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func pending(in context: ModelContext) throws -> [PendingChange] {
        try context.fetch(FetchDescriptor<PendingChange>(
            sortBy: [SortDescriptor(\.queuedAt, order: .forward)]
        ))
    }

    private func makeItem(id: String = "feed/1#1", in context: ModelContext) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        let item = CachedItem(
            id: id,
            sourceID: "feed/1",
            accountID: accountID,
            kind: .article,
            title: "A fine widget",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key
        )
        context.insert(item)
        return item
    }

    // MARK: - Positions

    @Test("A position is queued under the same key its record uses")
    func queuesPosition() throws {
        let context = try makeContext()
        let mark = try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "feed/1#1"),
            deviceID: "device-a",
            in: context
        )

        try SyncOutbox.record(mark, in: context)
        try context.save()

        let queued = try pending(in: context)
        #expect(queued.count == 1)
        #expect(queued[0].collection == .position)
        #expect(queued[0].recordID == mark.key)
        #expect(!queued[0].isDeletion)

        let payload = try SyncPayloadCoding.decode(
            PositionPayload.self,
            from: String(decoding: queued[0].payload, as: UTF8.self)
        )
        #expect(payload.deviceID == "device-a")
        #expect(payload.markSortKey == mark.markSortKeyRaw)
    }

    @Test("Scrolling repeatedly leaves one queued position, not one per stop")
    func positionsCoalesce() throws {
        let context = try makeContext()

        for offset in 0..<5 {
            let mark = try ThresholdService.setPosition(
                .all,
                to: SortKey(millis: 1_700_000_000_000 + Int64(offset) * 1_000, id: "feed/1#\(offset)"),
                deviceID: "device-a",
                in: context
            )
            try SyncOutbox.record(mark, in: context)
        }
        try context.save()

        let queued = try pending(in: context)
        #expect(queued.count == 1)

        let payload = try SyncPayloadCoding.decode(
            PositionPayload.self,
            from: String(decoding: queued[0].payload, as: UTF8.self)
        )
        // Only the final state is worth sending, and it is the final state that is queued.
        #expect(payload.markSortKey == SortKey(millis: 1_700_000_004_000, id: "feed/1#4").rawValue)
    }

    @Test("Two devices' positions queue as separate records")
    func positionsAreKeyedPerDevice() throws {
        let context = try makeContext()

        for device in ["device-a", "device-b"] {
            let mark = try ThresholdService.setPosition(
                .all,
                to: SortKey(millis: 1_700_000_000_000, id: "feed/1#1"),
                deviceID: device,
                in: context
            )
            try SyncOutbox.record(mark, in: context)
        }
        try context.save()

        #expect(try pending(in: context).count == 2)
    }

    // MARK: - No-op writes

    @Test("Re-queueing an identical payload does not re-queue it")
    func identicalPayloadIsSkipped() throws {
        let context = try makeContext()
        let item = makeItem(in: context)

        try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: false, in: context)
        let entry = try #require(try ReadLaterService.entry(for: item.id, in: context))

        try SyncOutbox.record(entry, in: context)
        try context.save()
        let firstQueuedAt = try #require(try pending(in: context).first).queuedAt

        try SyncOutbox.record(entry, in: context)
        try context.save()

        // A record whose bytes have not changed would otherwise be pushed again on every sync —
        // which is what `SyncPayloadCoding.encoder` sorts its keys for.
        let queued = try pending(in: context)
        #expect(queued.count == 1)
        #expect(queued[0].queuedAt == firstQueuedAt)
    }

    @Test("A changed payload replaces the queued one and clears its failure count")
    func changedPayloadReplaces() throws {
        let context = try makeContext()
        let item = makeItem(in: context)

        try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: false, in: context)
        let entry = try #require(try ReadLaterService.entry(for: item.id, in: context))
        try SyncOutbox.record(entry, in: context)
        try context.save()

        let queued = try #require(try pending(in: context).first)
        queued.failureCount = 3

        entry.title = "A finer widget"
        try SyncOutbox.record(entry, in: context)
        try context.save()

        let updated = try #require(try pending(in: context).first)
        #expect(updated.failureCount == 0)

        let payload = try SyncPayloadCoding.decode(
            ReadLaterPayload.self,
            from: String(decoding: updated.payload, as: UTF8.self)
        )
        #expect(payload.title == "A finer widget")
    }

    // MARK: - Read Later

    @Test("Both halves of a toggle queue the right record")
    func toggleQueuesBothWays() throws {
        let context = try makeContext()
        let item = makeItem(in: context)

        let saved = try ReadLaterService.toggle(item, sourceTitle: "Feed", archiveContent: false, in: context)
        try SyncOutbox.record(saved, in: context)
        try context.save()

        var queued = try pending(in: context)
        #expect(queued.count == 1)
        #expect(queued[0].collection == .readLater)
        #expect(!queued[0].isDeletion)

        let removed = try ReadLaterService.toggle(item, sourceTitle: "Feed", archiveContent: false, in: context)
        try SyncOutbox.record(removed, in: context)
        try context.save()

        queued = try pending(in: context)
        // Replaced in place, not queued alongside: the record's final state is a deletion, and
        // pushing a save followed by a delete would just be work.
        #expect(queued.count == 1)
        #expect(queued[0].isDeletion)
        #expect(queued[0].payload.isEmpty)
    }

    @Test("A deletion queues a tombstone rather than nothing")
    func deletionQueuesTombstone() throws {
        let context = try makeContext()

        try SyncOutbox.recordReadLaterDeletion(itemID: "feed/1#1", in: context)
        try context.save()

        let queued = try pending(in: context)
        #expect(queued.count == 1)
        #expect(queued[0].isDeletion)
        // Without the tombstone the entry would simply be re-created by the next pull, which is the
        // failure mode that rules out deriving the outbox by diffing.
        #expect(queued[0].recordID == "feed/1#1")
    }

    // MARK: - Filters and accounts

    @Test("A filter rule queues its whole definition")
    func queuesFilter() throws {
        let context = try makeContext()
        let rule = FilterRule(name: "No sport", pattern: "football", fields: .title)
        context.insert(rule)

        try SyncOutbox.record(rule, in: context)
        try context.save()

        let queued = try #require(try pending(in: context).first)
        #expect(queued.collection == .filter)
        #expect(queued.recordID == rule.id.uuidString)

        let payload = try SyncPayloadCoding.decode(
            FilterPayload.self,
            from: String(decoding: queued.payload, as: UTF8.self)
        )
        #expect(payload.pattern == "football")
        #expect(payload.name == "No sport")
    }

    @Test("An account queues its servers and never a credential")
    func accountCarriesNoSecret() throws {
        let context = try makeContext()
        let account = AccountRecord(
            kind: .freshRSS,
            displayName: "Home FreshRSS",
            serverURLString: "https://rss.example.com",
            username: "matze"
        )
        context.insert(account)

        try SyncOutbox.record(account, in: context)
        try context.save()

        let queued = try #require(try pending(in: context).first)
        let json = String(decoding: queued.payload, as: UTF8.self).lowercased()

        // The security property the whole sync design rests on, asserted where the bytes are
        // actually produced rather than only where the payload type is declared.
        #expect(!json.contains("password"))
        #expect(!json.contains("token"))
        #expect(!json.contains("secret"))
        #expect(json.contains("rss.example.com"))
    }
}
