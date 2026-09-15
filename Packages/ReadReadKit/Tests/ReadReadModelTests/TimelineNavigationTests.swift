import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Covers the operations the timeline's "N newer" menu is built on, plus the invariant that ties
/// the three scope predicates together.
@Suite("Timeline navigation")
struct TimelineNavigationTests {

    // MARK: - Fixtures

    private let accountID = UUID()
    private let deviceID = "device-a"

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    /// Inserts `count` items one second apart, oldest first, so index 0 is the oldest and the
    /// last returned key is the newest.
    @discardableResult
    private func insertItems(
        count: Int,
        sourceID: String = "feed-a",
        folder: String? = nil,
        arrivedLate: Bool = false,
        isFilteredOut: Bool = false,
        startingAt base: Int64 = 1_700_000_000_000,
        in context: ModelContext
    ) -> [SortKey] {
        (0..<count).map { offset in
            let millis = base + Int64(offset) * 1_000
            let id = "\(sourceID)#\(offset)"
            let key = SortKey(millis: millis, id: id)
            context.insert(CachedItem(
                id: id,
                sourceID: sourceID,
                accountID: accountID,
                folderName: folder,
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key,
                arrivedLate: arrivedLate,
                isFilteredOut: isFilteredOut
            ))
            return key
        }
    }

    // MARK: - The item at the position

    /// `itemAtPosition` finds its answer by offsetting into the timeline by `newerCount`, so an
    /// off-by-one here would scroll the user one row away from where they left off — every time.
    @Test("The item at the position is the one the marker was set from")
    func itemAtPositionMatchesTheMark() throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, in: context)
        try context.save()

        // Mark at index 6, leaving indices 7, 8, 9 above it.
        try ThresholdService.setPosition(.all, to: keys[6], deviceID: deviceID, in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)

        let item = try ThresholdService.itemAtPosition(for: .all, in: context)
        #expect(item?.sortKey == keys[6])
    }

    @Test("An untouched scope positions at the oldest item")
    func untouchedScopePositionsAtOldest() throws {
        let context = try makeContext()
        let keys = insertItems(count: 5, in: context)
        try context.save()

        // Nothing has been read, so every item is above the marker and there is no item at it.
        // Offsetting past the end must yield nothing rather than wrapping to the newest, which
        // would send "Scroll to Timeline Position" to the top — the opposite of what it means.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 5)
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context) == nil)
        #expect(try ThresholdService.newestItem(for: .all, in: context)?.sortKey == keys[4])
    }

    @Test("A fully-read scope positions at the newest item")
    func fullyReadScopePositionsAtNewest() throws {
        let context = try makeContext()
        let keys = insertItems(count: 5, in: context)
        try context.save()

        try ThresholdService.setPosition(.all, to: keys[4], deviceID: deviceID, in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.sortKey == keys[4])
    }

    /// The offset arithmetic is only valid if the offset query and the count query agree on which
    /// items exist. They share `ScopeQuery`, and this is the assertion that keeps them sharing it.
    @Test("Filtered items shift neither the count nor the position")
    func filteredItemsDoNotShiftThePosition() throws {
        let context = try makeContext()
        let visible = insertItems(count: 6, sourceID: "feed-a", in: context)
        // Interleaved in time, so a predicate that forgot to exclude them would move the offset.
        insertItems(
            count: 6,
            sourceID: "feed-spam",
            isFilteredOut: true,
            startingAt: 1_700_000_000_500,
            in: context
        )
        try context.save()

        try ThresholdService.setPosition(.all, to: visible[2], deviceID: deviceID, in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)
        #expect(try ThresholdService.itemAtPosition(for: .all, in: context)?.sortKey == visible[2])
    }

    @Test("Position resolution is per scope")
    func positionResolutionIsPerScope() throws {
        let context = try makeContext()
        let a = insertItems(count: 4, sourceID: "feed-a", folder: "News", in: context)
        let b = insertItems(count: 4, sourceID: "feed-b", startingAt: 1_700_000_100_000, in: context)
        try context.save()

        try ThresholdService.setPosition(.source("feed-a"), to: a[1], deviceID: deviceID, in: context)
        try context.save()

        #expect(try ThresholdService.itemAtPosition(for: .source("feed-a"), in: context)?.sortKey == a[1])
        // `feed-b` has its own untouched marker, so it has no item at its position…
        #expect(try ThresholdService.itemAtPosition(for: .source("feed-b"), in: context) == nil)
        // …and its newest item is genuinely newer than anything in `feed-a`.
        #expect(try ThresholdService.newestItem(for: .source("feed-b"), in: context)?.sortKey == b[3])
        #expect(try ThresholdService.newestItem(for: .folder("News"), in: context)?.sortKey == a[3])
    }

    // MARK: - Late arrivals

    @Test("Clearing late arrivals dismisses the notice for that scope only")
    func clearingLateArrivalsIsScoped() throws {
        let context = try makeContext()
        insertItems(count: 3, sourceID: "feed-a", arrivedLate: true, in: context)
        insertItems(count: 2, sourceID: "feed-b", arrivedLate: true, in: context)
        try context.save()

        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 5)
        #expect(try ThresholdService.clearLateArrivals(for: .source("feed-a"), in: context) == 3)
        try context.save()

        #expect(try ThresholdService.lateArrivalCount(for: .source("feed-a"), in: context) == 0)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 2)
    }

    /// Dismissing the notice must not move the reading position: the items stay where they belong
    /// chronologically, they simply stop being advertised.
    @Test("Clearing late arrivals leaves the position alone")
    func clearingLateArrivalsLeavesPositionAlone() throws {
        let context = try makeContext()
        let keys = insertItems(count: 4, arrivedLate: true, in: context)
        try context.save()

        try ThresholdService.setPosition(.all, to: keys[1], deviceID: deviceID, in: context)
        try context.save()

        let before = try ThresholdService.effectivePosition(for: .all, in: context)
        _ = try ThresholdService.clearLateArrivals(for: .all, in: context)
        try context.save()

        let after = try ThresholdService.effectivePosition(for: .all, in: context)
        #expect(after.markSortKey == before.markSortKey)
        #expect(after.updatedAt == before.updatedAt)
    }

    // MARK: - The Older Items list

    /// Its own sidebar scope, and deliberately an *unpositioned* one: every item in it already
    /// sits below some marker, so a threshold over it would always read zero.
    @Test("Older Items collects late arrivals across every scope")
    func lateArrivalScopeCollectsEverything() throws {
        let context = try makeContext()
        insertItems(count: 3, sourceID: "feed-a", folder: "News", arrivedLate: true, in: context)
        insertItems(count: 2, sourceID: "feed-b", arrivedLate: true, in: context)
        insertItems(count: 4, sourceID: "feed-c", in: context)
        try context.save()

        let listed = try context.fetch(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: .lateArrivals)
        ))
        #expect(listed.count == 5)
        #expect(listed.allSatisfy { $0.arrivedLate })
    }

    /// Unseeded, Older Items must count everything it holds — otherwise the one list whose whole
    /// job is to surface items you would not otherwise see would open reading zero.
    @Test("Older Items counts everything it holds until it has been read")
    func lateArrivalScopeCountsEverythingWhenUnread() throws {
        let context = try makeContext()
        insertItems(count: 4, arrivedLate: true, in: context)
        try context.save()

        // Nothing seeds this scope, so its marker sits at `distantPast` and every item is above it.
        #expect(try ThresholdService.effectivePosition(for: .lateArrivals, in: context).markSortKey == .distantPast)
        #expect(try ThresholdService.newerCount(for: .lateArrivals, in: context) == 4)
    }

    /// The bug this pins: scrolling Older Items to the top showed zero while the list was open and
    /// the full count came back the moment another scope was selected, because the badge was a
    /// plain count of flagged items with no marker behind it. Reading it has to *stick*.
    @Test("Reading Older Items lowers its count, and the count survives leaving the list")
    func lateArrivalScopeCountFollowsItsOwnPosition() throws {
        let context = try makeContext()
        insertItems(count: 4, arrivedLate: true, in: context)
        try context.save()

        let newest = try #require(try ThresholdService.newestItem(for: .lateArrivals, in: context))
        _ = try ThresholdService.setPosition(
            .lateArrivals,
            to: newest.sortKey,
            deviceID: "device-a",
            in: context
        )
        try context.save()

        // Scrolled to the top: nothing sits above the fold any more.
        #expect(try ThresholdService.newerCount(for: .lateArrivals, in: context) == 0)

        // And the items are still *there* — a position is not a dismissal.
        let listed = try context.fetch(FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: .lateArrivals)
        ))
        #expect(listed.count == 4)

        // A newly flagged item arriving above that position counts again.
        insertItems(count: 1, sourceID: "feed-b", arrivedLate: true, startingAt: 1_800_000_000_000, in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .lateArrivals, in: context) == 1)
    }

    @Test("Dismissing everything empties the Older Items list")
    func dismissingEmptiesTheList() throws {
        let context = try makeContext()
        insertItems(count: 3, sourceID: "feed-a", arrivedLate: true, in: context)
        insertItems(count: 2, sourceID: "feed-b", arrivedLate: true, in: context)
        try context.save()

        let cleared = try ThresholdService.clearLateArrivals(for: .lateArrivals, in: context)
        #expect(cleared == 5)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .lateArrivals, in: context) == 0)
        // Dismissing only stops advertising them; they stay in their chronological place.
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>()) == 5)
    }

    @Test("A filtered late arrival is not advertised")
    func filteredLateArrivalIsNotListed() throws {
        let context = try makeContext()
        insertItems(count: 2, sourceID: "feed-a", arrivedLate: true, in: context)
        insertItems(count: 3, sourceID: "feed-spam", arrivedLate: true, isFilteredOut: true, in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .lateArrivals, in: context) == 2)
    }

    // MARK: - Predicate agreement

    /// The three predicates are three views of one set. A filtered item must be absent from all of
    /// them: present in the display set but excluded from the count, the count disagrees with the
    /// list it is counting — which reads as a sync bug and is very hard to attribute.
    @Test("A filtered item is absent from all three scope predicates")
    func filteredItemIsAbsentEverywhere() throws {
        let context = try makeContext()
        insertItems(count: 4, sourceID: "feed-a", folder: "News", arrivedLate: true, in: context)
        insertItems(
            count: 4,
            sourceID: "feed-spam",
            folder: "News",
            arrivedLate: true,
            isFilteredOut: true,
            in: context
        )
        try context.save()

        let scopes: [ScopeID] = [.all, .folder("News"), .source("feed-spam")]

        for scope in scopes {
            let displayed = try context.fetch(
                FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: scope))
            )
            #expect(displayed.allSatisfy { !$0.isFilteredOut }, "display predicate for \(scope.rawValue)")

            let newer = try context.fetch(FetchDescriptor<CachedItem>(
                predicate: ScopeQuery.newerPredicate(for: scope, than: SortKey.distantPast.rawValue)!
            ))
            #expect(newer.allSatisfy { !$0.isFilteredOut }, "newer predicate for \(scope.rawValue)")

            let late = try context.fetch(FetchDescriptor<CachedItem>(
                predicate: ScopeQuery.lateArrivalPredicate(for: scope)!
            ))
            #expect(late.allSatisfy { !$0.isFilteredOut }, "late-arrival predicate for \(scope.rawValue)")
        }

        // And the display set and the "newer than nothing" set are the same set, which is the
        // property that makes `itemAtPosition`'s offset arithmetic valid.
        let displayed = try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: .all))
        )
        #expect(displayed == 4)
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 4)
    }

    /// Read Later is `ReadLaterEntry`, not `CachedItem`, so the item predicates have no meaning
    /// for it. They report that rather than silently matching everything.
    @Test("Read Later has no item predicates")
    func readLaterHasNoItemPredicates() throws {
        #expect(ScopeQuery.newerPredicate(for: .readLater, than: "") == nil)
        #expect(ScopeQuery.lateArrivalPredicate(for: .readLater) == nil)

        let context = try makeContext()
        insertItems(count: 3, in: context)
        try context.save()

        let matched = try context.fetch(
            FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: .readLater))
        )
        #expect(matched.isEmpty)
    }
}
