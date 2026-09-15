import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Retention deletes the user's data, and every one of its keep-rules fails silently: a count
/// drifts down on its own, a saved item's row vanishes, a backfilled archive is gone before it was
/// ever read. So each rule is pinned separately rather than through one end-to-end pass.
@Suite("Retention")
struct RetentionTests {

    private let accountID = UUID()
    private let sourceID = "freshrss:acct:feed/1"
    private let deviceID = "device-a"

    /// Small enough to reason about: three kept per source, anything older than a day eligible.
    private let policy = RetentionPolicy(itemsPerSource: 3, maximumAge: 24 * 60 * 60)

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> ModelContainer {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        context.insert(CachedSource(
            id: sourceID,
            accountID: accountID,
            kind: .article,
            title: "A Feed",
            folderName: "News"
        ))
        try context.save()
        return container
    }

    /// - Parameters:
    ///   - publishedDaysAgo: Drives `sortKey`, which is what the timeline and every count order by.
    ///   - arrivedDaysAgo: Drives `ingestKey`, which is what retention ages by. Separate on
    ///     purpose — the gap between them is the whole reason `ingestKey` exists.
    @discardableResult
    private func insert(
        _ id: String,
        publishedDaysAgo: Double,
        arrivedDaysAgo: Double? = nil,
        in context: ModelContext
    ) -> CachedItem {
        let published = now.addingTimeInterval(-publishedDaysAgo * 24 * 60 * 60)
        let arrived = now.addingTimeInterval(-(arrivedDaysAgo ?? publishedDaysAgo) * 24 * 60 * 60)

        let item = CachedItem(
            id: id,
            sourceID: sourceID,
            accountID: accountID,
            folderName: "News",
            kind: .article,
            title: id,
            publishedAt: published,
            sortKey: SortKey(date: published, id: id),
            ingestKey: SortKey(date: arrived, id: id)
        )
        context.insert(item)
        return item
    }

    private func itemIDs(in container: ModelContainer) throws -> Set<String> {
        Set(try ModelContext(container).fetch(FetchDescriptor<CachedItem>()).map(\.id))
    }

    /// Ten items, one per day, all arrived when published, with the reading position at the top so
    /// nothing is held back by a marker.
    private func makeAgedStore() throws -> ModelContainer {
        let container = try makeStore()
        let context = ModelContext(container)
        for day in 1...10 {
            insert("item-\(day)", publishedDaysAgo: Double(day), in: context)
        }
        try ThresholdService.setPosition(
            .all,
            to: SortKey(date: now, id: "top"),
            deviceID: deviceID,
            in: context
        )
        try ThresholdService.setPosition(
            .source(sourceID),
            to: SortKey(date: now, id: "top"),
            deviceID: deviceID,
            in: context
        )
        try ThresholdService.setPosition(
            .folder("News"),
            to: SortKey(date: now, id: "top"),
            deviceID: deviceID,
            in: context
        )
        try context.save()
        return container
    }

    // MARK: - The fetch window

    /// The window rule, with the age rule switched off so each test isolates one of them.
    private var windowPolicy: RetentionPolicy {
        RetentionPolicy(itemsPerSource: 1000, maximumAge: 0, historyWindowDays: 5)
    }

    @Test("Items published outside the fetch window are pruned")
    func prunesOutsideTheFetchWindow() async throws {
        let container = try makeAgedStore()
        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)

        #expect(report.itemsDeleted == 5)
        #expect(try itemIDs(in: container) == ["item-1", "item-2", "item-3", "item-4", "item-5"])
    }

    @Test("The per-source count floor does not hold items inside the fetch window")
    func windowIgnoresTheCountFloor() async throws {
        // The state that made this necessary: a thousand kept per source is far more than the
        // store holds, so the count floor protected every item and nothing was ever pruned.
        let container = try makeAgedStore()
        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: RetentionPolicy(), now: now)
        #expect(try itemIDs(in: container).count == 10, "the age rule alone cannot prune this")

        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)
        #expect(try itemIDs(in: container).count == 5)
    }

    @Test("An unlimited window prunes nothing by publication date")
    func unlimitedWindowPrunesNothing() async throws {
        let container = try makeAgedStore()
        let policy = RetentionPolicy(
            itemsPerSource: 1000,
            maximumAge: 0,
            historyWindowDays: HistoryWindow.unlimited
        )

        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        #expect(report == RetentionReport())
        #expect(try itemIDs(in: container).count == 10)
    }

    @Test("The fetch window never deletes an item above a reading position")
    func windowKeepsItemsAboveTheMarker() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        for day in 1...10 {
            insert("item-\(day)", publishedDaysAgo: Double(day), in: context)
        }
        // Eight days behind: items 1–8 are above the fold, and five of those are outside the
        // window. Deleting them would drop the count on its own — the failure that reads as items
        // being silently marked read.
        try ThresholdService.setPosition(
            .all,
            to: SortKey(date: now.addingTimeInterval(-8 * 24 * 60 * 60), id: "mark"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        let before = try ThresholdService.newerCount(for: .all, in: ModelContext(container))
        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)

        #expect(try ThresholdService.newerCount(for: .all, in: ModelContext(container)) == before)
        #expect(try itemIDs(in: container).isSuperset(of: (1...8).map { "item-\($0)" }))
    }

    @Test("The fetch window never deletes a saved item")
    func windowKeepsSavedItems() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)
        let saved = try #require(
            try context.fetch(FetchDescriptor<CachedItem>(
                predicate: #Predicate { $0.id == "item-9" }
            )).first
        )
        _ = try ReadLaterService.toggle(saved, sourceTitle: "A Feed", archiveContent: false, in: context)
        try context.save()

        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)

        #expect(try itemIDs(in: container).contains("item-9"))
    }

    @Test("The fetch window never deletes a late arrival")
    func windowKeepsLateArrivals() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)
        // A feed backfilling its archive: published long before the window, arrived today. It is
        // below the marker by definition, so only the flag can save it.
        let late = insert("backfilled", publishedDaysAgo: 400, arrivedDaysAgo: 0, in: context)
        late.arrivedLate = true
        try context.save()

        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)

        #expect(try itemIDs(in: container).contains("backfilled"))

        // Once dismissed it is ordinary history again, and the window may take it.
        let fresh = ModelContext(container)
        try ThresholdService.clearLateArrivals(for: .all, in: fresh)
        try fresh.save()

        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)
        #expect(try !itemIDs(in: container).contains("backfilled"))
    }

    @Test("A late arrival the reader has already scrolled past is prunable")
    func windowPrunesDismissedLateArrivals() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)
        let late = insert("backfilled", publishedDaysAgo: 400, arrivedDaysAgo: 0, in: context)
        late.arrivedLate = true
        // Read to the top of Older Items, which is what the badge showing zero means. The flag is
        // still set — nothing clears it — so a blanket exemption on it would pin this row forever.
        try ThresholdService.setPosition(
            .lateArrivals,
            to: SortKey(date: now, id: "top"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: windowPolicy, now: now)

        #expect(try !itemIDs(in: container).contains("backfilled"))
    }

    @Test("Both rules run in one pass")
    func bothRulesApplyTogether() async throws {
        let container = try makeAgedStore()
        let report = try await RetentionService(modelContainer: container).prune(
            accountIDs: [accountID],
            policy: RetentionPolicy(itemsPerSource: 3, maximumAge: 24 * 60 * 60, historyWindowDays: 5),
            now: now
        )

        // The age rule takes items 4–10 (older than a day, outside the newest three); the window
        // rule would take 6–10. Neither double-counts what the other already removed.
        #expect(report.itemsDeleted == 7)
        #expect(try itemIDs(in: container) == ["item-1", "item-2", "item-3"])
    }

    // MARK: - The keep-window

    @Test("Old items beyond the keep-window are pruned")
    func prunesOldItemsBeyondWindow() async throws {
        let container = try makeAgedStore()
        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        #expect(report.itemsDeleted == 7)
        // Newest three kept by count; the rest are a day or more old and below every marker.
        #expect(try itemIDs(in: container) == ["item-1", "item-2", "item-3"])
    }

    @Test("A source with fewer items than the window keeps all of them")
    func keepsEverythingBelowTheWindow() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        for day in 1...3 {
            insert("item-\(day)", publishedDaysAgo: Double(day) * 100, in: context)
        }
        try context.save()

        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // Ancient, but a feed you have read to the end of must not empty out.
        #expect(report.itemsDeleted == 0)
        #expect(try itemIDs(in: container).count == 3)
    }

    @Test("A recent item beyond the window is kept")
    func keepsRecentItems() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        for hour in 1...10 {
            insert("item-\(hour)", publishedDaysAgo: Double(hour) / 24, in: context)
        }
        try context.save()

        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // All ten arrived within the day, so the count rule alone must not evict them.
        #expect(report.itemsDeleted == 0)
    }

    // MARK: - Reading positions

    @Test("An item above a reading position is never pruned")
    func keepsItemsAboveTheMark() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)

        // Position at day 8: items 1–7 are above it and still waiting to be read.
        try ThresholdService.setPosition(
            .source(sourceID),
            to: SortKey(date: now.addingTimeInterval(-8 * 24 * 60 * 60), id: "item-8"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        _ = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // Deleting any of these would make the sidebar count fall on its own, which reads exactly
        // like items being silently marked read.
        let survivors = try itemIDs(in: container)
        for day in 1...8 {
            #expect(survivors.contains("item-\(day)"))
        }
        #expect(!survivors.contains("item-10"))
    }

    @Test("An item below its feed's position but above All Items is kept")
    func checksEveryScopeThatCountsTheItem() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)

        // The feed has been read to the top, but All Items has not — so these items still count
        // in the unified timeline. Checking only the source's own marker would delete them and
        // drop the All Items badge without anything being read.
        try ThresholdService.setPosition(
            .all,
            to: SortKey(date: now.addingTimeInterval(-9 * 24 * 60 * 60), id: "item-9"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        _ = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        let survivors = try itemIDs(in: container)
        #expect(survivors.contains("item-8"))
        #expect(!survivors.contains("item-10"))
    }

    // MARK: - Ageing by arrival, not publication

    @Test("A backfilled archive is not pruned the moment it arrives")
    func agesByArrivalNotPublication() async throws {
        let container = try makeStore()
        let context = ModelContext(container)

        // Four recent items fill the keep-window, then a feed backfills its 2019 archive: old
        // published dates, but they landed a minute ago.
        for day in 1...4 {
            insert("recent-\(day)", publishedDaysAgo: Double(day) / 24, in: context)
        }
        for year in 1...5 {
            insert("archive-\(year)", publishedDaysAgo: Double(year) * 365, arrivedDaysAgo: 0, in: context)
        }
        try context.save()

        _ = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // Ageing by published date would delete every one of these before it could be read — the
        // exact failure `ingestKey` exists to prevent.
        let survivors = try itemIDs(in: container)
        for year in 1...5 {
            #expect(survivors.contains("archive-\(year)"))
        }
    }

    // MARK: - Read Later

    @Test("A saved item is never pruned")
    func keepsSavedItems() async throws {
        let container = try makeAgedStore()
        let context = ModelContext(container)

        let doomed = try #require(
            try context.fetch(FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == "item-10" })).first
        )
        try ReadLaterService.save(doomed, sourceTitle: "A Feed", archiveContent: false, in: context)
        try context.save()

        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // The entry carries its own snapshot, so the saved item would still open — but its row in
        // the timeline would vanish, and saving something is a promise.
        #expect(try itemIDs(in: container).contains("item-10"))
        #expect(report.itemsDeleted == 6)
    }

    // MARK: - Scoping

    @Test("An account that did not complete its run is not pruned")
    func skipsAccountsThatDidNotComplete() async throws {
        let container = try makeAgedStore()

        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [UUID()], policy: policy, now: now)

        // Pruning behind an interrupted walk evicts exactly the items the next run was about to
        // restore — and then evicts them again next time.
        #expect(report.itemsDeleted == 0)
        #expect(try itemIDs(in: container).count == 10)
    }

    @Test("No accounts means no work")
    func emptyAccountListDoesNothing() async throws {
        let container = try makeAgedStore()
        let report = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [], policy: policy, now: now)

        #expect(report == RetentionReport())
        #expect(try itemIDs(in: container).count == 10)
    }

    @Test("Each source keeps its own window")
    func windowIsPerSource() async throws {
        let container = try makeStore()
        let context = ModelContext(container)

        let quietID = "freshrss:acct:feed/2"
        context.insert(CachedSource(id: quietID, accountID: accountID, kind: .article, title: "Quiet"))

        for day in 1...10 {
            insert("busy-\(day)", publishedDaysAgo: Double(day), in: context)
        }
        // One item, published long ago, from a source that rarely posts.
        let published = now.addingTimeInterval(-400 * 24 * 60 * 60)
        context.insert(CachedItem(
            id: "quiet-1",
            sourceID: quietID,
            accountID: accountID,
            kind: .article,
            title: "Quiet",
            publishedAt: published,
            sortKey: SortKey(date: published, id: "quiet-1"),
            ingestKey: SortKey(date: published, id: "quiet-1")
        ))
        try ThresholdService.setPosition(.all, to: SortKey(date: now, id: "top"), deviceID: deviceID, in: context)
        try context.save()

        _ = try await RetentionService(modelContainer: container)
            .prune(accountIDs: [accountID], policy: policy, now: now)

        // A global window would let the busy feed evict the quiet one entirely.
        #expect(try itemIDs(in: container).contains("quiet-1"))
    }
}
