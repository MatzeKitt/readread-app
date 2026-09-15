import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The timeline list, the sidebar count and the "older items arrived" list are three views of the
/// same set of items. They only agree if they share a definition, and when they disagree it reads
/// as a sync bug — a badge saying 3 over a list showing 5, with nothing to attribute it to.
///
/// So the shape of this suite is: for every exclusion, assert it holds in **all three** at once.
@Suite("ScopeQuery")
struct ScopeQueryTests {

    private let accountID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    private let otherAccountID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
    private let deviceID = "device-a"

    private var sourceID: String { "freshrss:\(accountID):feed/1" }
    private var otherSourceID: String { "freshrss:\(accountID):feed/2" }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    @discardableResult
    private func insert(
        _ id: String,
        in context: ModelContext,
        sourceID: String? = nil,
        accountID: UUID? = nil,
        folderName: String? = "News",
        millis: Int64 = 1_700_000_000_000,
        arrivedLate: Bool = false,
        isFilteredOut: Bool = false,
        isAccountEnabled: Bool = true
    ) -> CachedItem {
        let key = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: sourceID ?? self.sourceID,
            accountID: accountID ?? self.accountID,
            folderName: folderName,
            kind: .article,
            title: id,
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: key,
            ingestKey: key,
            arrivedLate: arrivedLate,
            isFilteredOut: isFilteredOut,
            isAccountEnabled: isAccountEnabled
        )
        context.insert(item)
        return item
    }

    /// What each of the three views reports for a scope.
    private func views(of scope: ScopeID, in context: ModelContext) throws -> (displayed: Int, newer: Int, late: Int) {
        let displayed = try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: scope))
        )
        let newer = try ThresholdService.newerCount(for: scope, in: context)
        let late = try ScopeQuery.lateArrivalPredicate(for: scope).map {
            try context.fetchCount(FetchDescriptor<CachedItem>(predicate: $0))
        } ?? 0
        return (displayed, newer, late)
    }

    // MARK: - Membership

    @Test("A source scope contains only that source's items")
    func sourceScopeMembership() throws {
        let context = try makeContext()
        insert("a", in: context)
        insert("b", in: context, sourceID: otherSourceID)
        try context.save()

        #expect(try views(of: .source(sourceID), in: context).displayed == 1)
        #expect(try views(of: .all, in: context).displayed == 2)
    }

    @Test("A folder scope matches the item's denormalised folder")
    func folderScopeMembership() throws {
        let context = try makeContext()
        insert("a", in: context, folderName: "News")
        insert("b", in: context, folderName: "Tech")
        try context.save()

        // Matched on the item's own copy rather than by joining through its source, which is what
        // makes a folder count one index lookup instead of an `IN (…)` over every source in it.
        #expect(try views(of: .folder("News"), in: context).displayed == 1)
    }

    @Test("A Mastodon home scope resolves to its source")
    func mastodonHomeResolvesToSource() throws {
        let context = try makeContext()
        let homeID = SourceIdentifier.mastodonHome(accountID: accountID)
        insert("a", in: context, sourceID: homeID, folderName: nil)
        insert("b", in: context)
        try context.save()

        // Two `ScopeID` raw values over one set of items: if these disagreed, the timeline would
        // read zero while the sidebar showed the whole backlog.
        #expect(try views(of: .mastodonHome(accountID: accountID), in: context).displayed == 1)
    }

    @Test("Read Later has no CachedItem form")
    func readLaterHasNoItems() throws {
        let context = try makeContext()
        insert("a", in: context)
        try context.save()

        // Its entries are `ReadLaterEntry` snapshots, so that saving something survives pruning.
        #expect(try views(of: .readLater, in: context).displayed == 0)
        #expect(ScopeQuery.lateArrivalPredicate(for: .readLater) == nil)
        #expect(ScopeQuery.newerPredicate(for: .readLater, than: "") == nil)
    }

    @Test("The late-arrivals scope gathers them from every source")
    func lateArrivalsAreGlobal() throws {
        let context = try makeContext()
        insert("a", in: context, arrivedLate: true)
        insert("b", in: context, sourceID: otherSourceID, folderName: "Tech", arrivedLate: true)
        insert("c", in: context)
        try context.save()

        // An item is flagged relative to whichever marker it landed under, so one place to find
        // all of them is the only useful presentation.
        #expect(try views(of: .lateArrivals, in: context).displayed == 2)
    }

    // MARK: - The threshold is a position, not a filter

    @Test("The timeline shows items below the marker")
    func displayCarriesNoThreshold() throws {
        let context = try makeContext()
        insert("old", in: context, millis: 1_700_000_000_000)
        insert("new", in: context, millis: 1_800_000_000_000)
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_800_000_000_000, id: "new"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        let result = try views(of: .all, in: context)
        // Hiding items below the marker is what an unread-based reader does, and is exactly the
        // behaviour this design replaces.
        #expect(result.displayed == 2)
        #expect(result.newer == 0)
    }

    @Test("The newer count is strict about the item at the marker")
    func newerCountIsStrict() throws {
        let context = try makeContext()
        insert("a", in: context, millis: 1_700_000_000_000)
        insert("b", in: context, millis: 1_800_000_000_000)
        try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_700_000_000_000, id: "a"),
            deviceID: deviceID,
            in: context
        )
        try context.save()

        // The item *at* the fold is the position, not something above it.
        #expect(try views(of: .all, in: context).newer == 1)
    }

    @Test("An item with an empty sort key still appears in the timeline")
    func emptySortKeyStillLists() throws {
        let context = try makeContext()
        let item = insert("a", in: context)
        item.sortKeyRaw = ""
        try context.save()

        // `displayPredicate` is deliberately its own switch rather than `newerPredicate` with a
        // floor of `distantPast`: that floor is the empty string and the comparison is strict, so
        // this row would vanish from the app with nothing to attribute it to.
        #expect(try views(of: .all, in: context).displayed == 1)
    }

    // MARK: - Exclusions, in all three views at once

    @Test("A filtered item is absent from the list, the count and the late-arrival list")
    func filteredItemIsAbsentEverywhere() throws {
        let context = try makeContext()
        insert("hidden", in: context, arrivedLate: true, isFilteredOut: true)
        insert("shown", in: context, arrivedLate: true)
        try context.save()

        #expect(try views(of: .all, in: context) == (1, 1, 1))
        #expect(try views(of: .source(sourceID), in: context) == (1, 1, 1))
        #expect(try views(of: .folder("News"), in: context) == (1, 1, 1))
    }

    @Test("A disabled account's items are absent from all three too")
    func disabledAccountIsAbsentEverywhere() throws {
        let context = try makeContext()
        insert("a", in: context, arrivedLate: true)
        insert("b", in: context, arrivedLate: true)
        try context.save()

        #expect(try views(of: .all, in: context) == (2, 2, 2))

        try ThresholdService.setAccountEnabled(false, forAccountID: accountID, in: context)
        try context.save()

        // Switching an account off and still seeing its posts in All Items reads as the switch
        // not working.
        #expect(try views(of: .all, in: context) == (0, 0, 0))
        #expect(try views(of: .lateArrivals, in: context) == (0, 0, 0))
    }

    @Test("Disabling one account leaves the others alone")
    func disablingIsPerAccount() throws {
        let context = try makeContext()
        insert("mine", in: context)
        insert("theirs", in: context, sourceID: "freshrss:\(otherAccountID):feed/9", accountID: otherAccountID)
        try context.save()

        try ThresholdService.setAccountEnabled(false, forAccountID: accountID, in: context)
        try context.save()

        #expect(try views(of: .all, in: context).displayed == 1)
    }

    @Test("Re-enabling an account brings its items back")
    func reenablingRestores() throws {
        let context = try makeContext()
        insert("a", in: context)
        try context.save()

        try ThresholdService.setAccountEnabled(false, forAccountID: accountID, in: context)
        try ThresholdService.setAccountEnabled(true, forAccountID: accountID, in: context)
        try context.save()

        // Hidden, not deleted: the ingest cursor would refuse to re-fetch a backlog it has already
        // walked past, so deleting would lose those items permanently.
        #expect(try views(of: .all, in: context).displayed == 1)
    }

    @Test("Reconciliation catches an account switched off elsewhere")
    func reconciliationCatchesUp() throws {
        let context = try makeContext()

        let account = AccountRecord(
            id: accountID,
            kind: .freshRSS,
            displayName: "Off",
            serverURLString: "https://rss.example.com",
            username: "matze"
        )
        // Switched off on another device and pulled in by sync, so no toggle ran here.
        account.isEnabled = false
        context.insert(account)
        insert("a", in: context)
        try context.save()

        #expect(try ThresholdService.reconcileAccountVisibility(in: context) == 1)
        #expect(try views(of: .all, in: context).displayed == 0)
        // Idempotent: a second pass finds nothing to do, which is what makes it safe at launch.
        #expect(try ThresholdService.reconcileAccountVisibility(in: context) == 0)
    }
}
