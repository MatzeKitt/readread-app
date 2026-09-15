import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The migration rewrites the field the whole threshold design compares on, so the thing worth
/// testing is not that the keys changed — it is that the reader keeps their place across the
/// change, which is the part that fails silently.
@Suite("Sort basis migration")
struct SortBasisMigrationTests {

    private let accountID = UUID()
    private let sourceID = "freshrss:acct:feed/1"
    private let device = "device-a"

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        context.insert(CachedSource(
            id: sourceID,
            accountID: accountID,
            kind: .article,
            title: "A Feed",
            folderName: "News"
        ))
        return context
    }

    /// Inserts an item whose published and fetch dates disagree, which is the whole point.
    @discardableResult
    private func insert(
        _ id: String,
        publishedMillis: Int64,
        fetchedMillis: Int64,
        in context: ModelContext
    ) -> CachedItem {
        let item = CachedItem(
            id: id,
            sourceID: sourceID,
            accountID: accountID,
            folderName: "News",
            kind: .article,
            title: id,
            publishedAt: Date(millisecondsSinceEpoch: publishedMillis),
            sortKey: SortKey(millis: publishedMillis, id: id),
            ingestKey: SortKey(millis: fetchedMillis, id: id)
        )
        context.insert(item)
        return item
    }

    private func timeline(_ context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: .all),
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )).map(\.id)
    }

    /// Three items fetched in order a, b, c, but published out of order — `b` claims a date far in
    /// the future and `c` claims one from years ago.
    private func makeMisdatedStore() throws -> ModelContext {
        let context = try makeContext()
        insert("a", publishedMillis: 1_700_000_000_000, fetchedMillis: 1_700_000_000_000, in: context)
        insert("b", publishedMillis: 1_900_000_000_000, fetchedMillis: 1_700_000_100_000, in: context)
        insert("c", publishedMillis: 1_500_000_000_000, fetchedMillis: 1_700_000_200_000, in: context)
        try context.save()
        return context
    }

    @Test("Ordering moves onto fetch time")
    func reordersOntoFetchTime() throws {
        let context = try makeMisdatedStore()
        #expect(try timeline(context) == ["b", "a", "c"], "the old basis, publisher-claimed")

        try SortBasisMigration.run(deviceID: device, in: context)

        #expect(try timeline(context) == ["c", "b", "a"], "newest fetched first")
    }

    @Test("The reader keeps their place")
    func preservesTheFold() throws {
        let context = try makeMisdatedStore()

        // Parked on `a`: under the old basis that is one item down from the top.
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "a"),
            deviceID: device,
            in: context
        )
        try context.save()
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.id == "a")
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 1)

        try SortBasisMigration.run(deviceID: device, in: context)

        // Still on `a`, which is now the *oldest* item — so the count follows the new order rather
        // than the old number. Preserving the number instead would leave the marker on a different
        // item, which is the failure that reads as items being marked read by themselves.
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.id == "a")
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 2)
    }

    @Test("A future-dated item stops holding the position ahead of real time")
    func futureDatedItemNoLongerPinsTheMarker() throws {
        let context = try makeMisdatedStore()

        // Scrolled to the top under the old basis, which parks the marker on `b` — a date years in
        // the future. Every item fetched afterwards sorts below it and is never counted as new.
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_900_000_000_000, id: "b"),
            deviceID: device,
            in: context
        )
        try context.save()

        insert("d", publishedMillis: 1_700_000_300_000, fetchedMillis: 1_700_000_300_000, in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0, "the bug")

        try SortBasisMigration.run(deviceID: device, in: context)

        // `b` was fetched second of four, so two items sit above it once order follows fetch time.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 2)
    }

    @Test("Late-arrival flags are cleared, because they were decided in the old basis")
    func clearsLateArrivalFlags() throws {
        let context = try makeMisdatedStore()
        for item in try context.fetch(FetchDescriptor<CachedItem>()) {
            item.arrivedLate = true
        }
        try context.save()

        let report = try SortBasisMigration.run(deviceID: device, in: context)

        #expect(report.lateFlagsCleared == 3)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 0)
    }

    @Test("A saved item's snapshot key is refreshed")
    func rekeysSavedEntries() throws {
        let context = try makeMisdatedStore()
        let item = try #require(
            try context.fetch(FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == "c" })).first
        )
        _ = try ReadLaterService.toggle(item, sourceTitle: "A Feed", archiveContent: false, in: context)
        try context.save()

        try SortBasisMigration.run(deviceID: device, in: context)

        let entry = try #require(try ReadLaterService.entry(for: "c", in: context))
        #expect(entry.sortKey == SortKey(millis: 1_700_000_200_000, id: "c"))
    }

    @Test("The Read Later marker is moved onto the entry it was sitting on")
    func movesTheReadLaterMarker() throws {
        let context = try makeMisdatedStore()
        for id in ["a", "c"] {
            let item = try #require(
                try context.fetch(FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })).first
            )
            _ = try ReadLaterService.toggle(item, sourceTitle: "A Feed", archiveContent: false, in: context)
        }
        // A marker partway down the saved list, which is what makes this test able to fail: with
        // the marker still at `distantPast` every entry counts either way and nothing is proven.
        try ThresholdService.setPosition(
            .readLater,
            to: SortKey(millis: 1_500_000_000_000, id: "c"),
            deviceID: device,
            in: context
        )
        try context.save()

        #expect(try ThresholdService.newerCount(for: .readLater, in: context) == 1)

        try SortBasisMigration.run(deviceID: device, in: context)

        // Read Later orders its own snapshots, so re-keying those without moving this marker
        // leaves it holding a key from the old basis — below both entries rather than between
        // them, and the count jumps to 2. The marker has to land back on `c`, the entry it was on.
        let mark = try ThresholdService.effectivePosition(for: .readLater, in: context).markSortKey
        let entry = try #require(try ReadLaterService.entry(for: "c", in: context))
        #expect(mark == entry.sortKey)

        // The count follows the new order rather than the old number — `c` was fetched after `a`,
        // so it is now the newest saved item and nothing sits above it. Same trade as the timeline.
        #expect(try ThresholdService.newerCount(for: .readLater, in: context) == 0)
    }

    @Test("Another device's marker is left for that device to migrate")
    func leavesOtherDevicesAlone() throws {
        let context = try makeMisdatedStore()
        let foreign = SortKey(millis: 1_900_000_000_000, id: "b")
        try ThresholdService.setPosition(.all, to: foreign, deviceID: "iphone", in: context)
        try context.save()

        try SortBasisMigration.run(deviceID: device, in: context)

        let rows = try context.fetch(FetchDescriptor<PositionMark>(
            predicate: #Predicate { $0.deviceID == "iphone" }
        ))
        #expect(rows.count == 1)
        #expect(rows.first?.markSortKey == foreign, "not ours to rewrite")

        // This device's own row was written, and later, so it wins the reduction meanwhile.
        #expect(try ThresholdService.effectivePosition(for: .all, in: context).markSortKey != foreign)
    }

    @Test("Running twice changes nothing the second time")
    func isIdempotent() throws {
        let context = try makeMisdatedStore()
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "a"),
            deviceID: device,
            in: context
        )
        try context.save()

        try SortBasisMigration.run(deviceID: device, in: context)
        let order = try timeline(context)
        let fold = try ThresholdService.itemAtPosition(for: .all, in: context)?.id

        let second = try SortBasisMigration.run(deviceID: device, in: context)

        #expect(second.itemsRekeyed == 0)
        #expect(second.lateFlagsCleared == 0)
        #expect(try timeline(context) == order)
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.id == fold)
    }

    @Test("The guard runs the pass once and then stops")
    func guardRunsOnce() throws {
        let context = try makeMisdatedStore()
        let defaults = UserDefaults(suiteName: "readread.migration.\(UUID().uuidString)")!

        let first = try SortBasisMigration.runIfNeeded(deviceID: device, in: context, defaults: defaults)
        #expect(first.itemsRekeyed == 2)

        insert("e", publishedMillis: 1_900_000_000_000, fetchedMillis: 1_700_000_400_000, in: context)
        try context.save()

        // A store already on the current basis is not walked again, so an item written *after* the
        // migration keeps whatever its ingest gave it — which the new planner already gets right.
        let second = try SortBasisMigration.runIfNeeded(deviceID: device, in: context, defaults: defaults)
        #expect(second == SortBasisMigration.Report())
    }
}
