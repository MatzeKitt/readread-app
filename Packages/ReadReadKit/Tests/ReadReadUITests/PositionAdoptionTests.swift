import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadUI

/// What an open list does with a position another device reported.
///
/// The reported failure this pins: three unread on the phone, the Mac scrolled to the top, and the
/// phone — asked to load the new data — stayed where it was. The other direction worked every
/// time, which is the signature of a rule that depends on which device's ids happen to sort first
/// rather than on what the reader did.
@Suite("Position adoption")
struct PositionAdoptionTests {

    // MARK: - The decision

    /// The regression. Scrolling to the top on the Mac marks the newest item *the Mac* has, and a
    /// phone that has been asleep has not ingested it yet — so the report arrives ahead of the
    /// article it names. Acting on it then means placing the reader by an offset into a key space
    /// this store cannot compare, and recording it means the correct answer never gets a turn.
    @Test("A report whose article has not arrived is deferred, not approximated")
    func unplaceableReportWaits() {
        #expect(
            PositionAdoption.decide(
                isAlreadyAdopted: false,
                isPlaceable: false,
                isFoldAtReport: false
            ) == .waitForItems
        )
    }

    /// And deferring has to mean *unrecorded*, or the retry it exists for cannot happen. This is
    /// the pairing that was broken: the old code deferred nothing and recorded everything.
    @Test("The same report is acted on once its article arrives")
    func placeableReportScrolls() {
        let reported = SortKey(millis: 1_000, id: "i1")

        // Before ingest: nothing happens, and nothing is remembered.
        let first = PositionAdoption.decide(
            isAlreadyAdopted: false,
            isPlaceable: false,
            isFoldAtReport: false
        )
        #expect(first == .waitForItems)

        // After ingest, the caller is still holding no record of it — so the same report, now
        // placeable, is applied.
        let second = PositionAdoption.decide(
            isAlreadyAdopted: false,
            isPlaceable: true,
            isFoldAtReport: false
        )
        #expect(second == .scroll)
        #expect(reported == SortKey(millis: 1_000, id: "i1"))
    }

    /// The jump this mechanism must not bring back: a report already acted on stays acted on,
    /// however often this store's translation of it moves afterwards.
    @Test("A report already applied is never applied twice")
    func appliedReportIsIgnored() {
        #expect(
            PositionAdoption.decide(
                isAlreadyAdopted: true,
                isPlaceable: true,
                isFoldAtReport: false
            ) == .ignore
        )
    }

    /// Being already applied outranks everything, including a report that has become unplaceable
    /// because retention pruned the article since. Re-deferring it would let it fire again later.
    @Test("An applied report is not reopened by its article going away")
    func appliedReportIsNotReopenedWhenPruned() {
        #expect(
            PositionAdoption.decide(
                isAlreadyAdopted: true,
                isPlaceable: false,
                isFoldAtReport: false
            ) == .ignore
        )
    }

    /// The common case: this device's own push comes back under its own id, every scope it
    /// cascaded to reports the same key, and the list is already there. Remembered so it is not
    /// reconsidered, but nothing is scrolled — scrolling here is what made the list twitch.
    @Test("A report the list already sits on is recorded without scrolling")
    func foldAlreadyThereRecordsOnly() {
        #expect(
            PositionAdoption.decide(
                isAlreadyAdopted: false,
                isPlaceable: true,
                isFoldAtReport: true
            ) == .recordOnly
        )
    }

    // MARK: - Placeability

    private func makeStore() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func insert(_ id: String, millis: Int64, in context: ModelContext) -> CachedItem {
        let key = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: "freshrss:acct:feed/1",
            accountID: UUID(),
            kind: .article,
            title: "Item",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: key,
            ingestKey: key
        )
        context.insert(item)
        return item
    }

    /// The fact `itemAtPosition` cannot supply. It finds the item at the marker by offset, so it
    /// answers for any non-empty scope — which is why "there is an item there" was mistaken for
    /// "the item the mark names is here".
    /// The trap in full: a marker this store cannot place still has an item sitting "at" it,
    /// because the offset query counts rows rather than finding the one the mark names.
    @Test("A mark naming an item this store does not have is not placeable")
    func absentItemIsNotPlaceable() throws {
        let context = try makeStore()
        let older = insert("older", millis: 1_000, in: context)
        _ = insert("newer", millis: 3_000, in: context)

        // What arrives from the other device: a key from an id space this store has nothing in,
        // landing between the two local items.
        let foreign = SortKey(millis: 2_000, id: "elsewhere")
        context.insert(PositionMark(scope: .all, deviceID: "device-B", markSortKey: foreign))
        try context.save()

        #expect(try !ThresholdService.holdsItem(at: foreign, for: .all, in: context))

        // And this is what the old guard asked instead. It answers — with the row the offset
        // happens to land on — so the report was applied to `older` and recorded as done.
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.id == older.id)
    }

    @Test("A mark naming an item this store has is placeable")
    func presentItemIsPlaceable() throws {
        let context = try makeStore()
        let item = insert("here", millis: 1_000, in: context)
        try context.save()

        #expect(try ThresholdService.holdsItem(at: item.sortKey, for: .all, in: context))
    }

    /// Every unread scope's marker is `distantPast`. Reading it as placeable would turn "nobody
    /// has read this" into a report worth scrolling to.
    @Test("A sentinel mark is never placeable")
    func sentinelIsNotPlaceable() throws {
        let context = try makeStore()
        _ = insert("here", millis: 1_000, in: context)
        try context.save()

        #expect(try !ThresholdService.holdsItem(at: .distantPast, for: .all, in: context))
        #expect(try !ThresholdService.holdsItem(at: .distantFuture, for: .all, in: context))
    }

    /// Read Later entries outlive the items they were taken from, so asking `CachedItem` there
    /// would call every saved article unplaceable the moment retention pruned it.
    @Test("Read Later is answered from its own rows")
    func readLaterUsesItsOwnRows() throws {
        let context = try makeStore()
        let key = SortKey(millis: 1_000, id: "saved")
        context.insert(ReadLaterEntry(
            itemID: "saved",
            sourceID: "freshrss:acct:feed/1",
            accountID: UUID(),
            kind: .article,
            title: "A saved article",
            sourceTitle: "Feed One",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: key
        ))
        try context.save()

        // The item itself is long gone, and the entry is still placeable.
        #expect(try ThresholdService.holdsItem(at: key, for: .readLater, in: context))
        #expect(try !ThresholdService.holdsItem(at: key, for: .all, in: context))
    }
}
