import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Pins the containment rules in `setPositionCascading`.
///
/// The bug these exist for was visible on screen and invisible in the tests that came before them:
/// `All Items: 9` sitting above a folder showing `46`. Every test here is written as a relation
/// between two counts rather than against a single expected number, because the relation is the
/// thing that was wrong — any individual count was correct about its own scope all along.
@Suite("Position cascade")
struct PositionCascadeTests {

    // MARK: - Fixtures

    private let accountID = UUID()
    private let device = "device-a"

    private var mastodonSourceID: String {
        SourceIdentifier.mastodonHome(accountID: accountID)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func insertSource(
        id: String,
        kind: ItemKind = .article,
        folder: String? = nil,
        isSubscribed: Bool = true,
        in context: ModelContext
    ) {
        context.insert(CachedSource(
            id: id,
            accountID: accountID,
            kind: kind,
            title: id,
            folderName: folder,
            isSubscribed: isSubscribed
        ))
    }

    /// Inserts `count` items into one source, oldest first, on a shared millisecond timeline so
    /// that items from different sources interleave the way they do in `All Items`.
    @discardableResult
    private func insertItems(
        count: Int,
        sourceID: String,
        kind: ItemKind = .article,
        folder: String? = nil,
        startingAt base: Int64,
        step: Int64 = 1_000,
        in context: ModelContext
    ) -> [SortKey] {
        (0..<count).map { offset in
            let millis = base + Int64(offset) * step
            let id = "\(sourceID)#\(offset)"
            let key = SortKey(millis: millis, id: id)
            context.insert(CachedItem(
                id: id,
                sourceID: sourceID,
                accountID: accountID,
                folderName: folder,
                kind: kind,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key
            ))
            return key
        }
    }

    private func mark(for scope: ScopeID, in context: ModelContext) throws -> SortKey {
        try ThresholdService.effectivePosition(for: scope, in: context).markSortKey
    }

    private func count(_ scope: ScopeID, in context: ModelContext) throws -> Int {
        try ThresholdService.newerCount(for: scope, in: context)
    }

    /// Two article feeds in `News`, one in `Blogs`, plus a Mastodon home timeline, all interleaved.
    private func makeTree(in context: ModelContext) throws -> [SortKey] {
        insertSource(id: "feed-a", folder: "News", in: context)
        insertSource(id: "feed-b", folder: "News", in: context)
        insertSource(id: "feed-c", folder: "Blogs", in: context)
        insertSource(id: mastodonSourceID, kind: .status, in: context)

        var keys: [SortKey] = []
        keys += insertItems(count: 5, sourceID: "feed-a", folder: "News", startingAt: 1_700_000_000_000, step: 4_000, in: context)
        keys += insertItems(count: 5, sourceID: "feed-b", folder: "News", startingAt: 1_700_000_001_000, step: 4_000, in: context)
        keys += insertItems(count: 5, sourceID: "feed-c", folder: "Blogs", startingAt: 1_700_000_002_000, step: 4_000, in: context)
        keys += insertItems(count: 5, sourceID: mastodonSourceID, kind: .status, startingAt: 1_700_000_003_000, step: 4_000, in: context)
        try context.save()

        return keys.sorted()
    }

    // MARK: - Downward

    @Test("Scrolling All Items carries every folder and feed to the same key")
    func allItemsCarriesItsContents() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)
        let target = keys[11]

        try ThresholdService.setPositionCascading(.all, to: target, deviceID: device, in: context)
        try context.save()

        for scope: ScopeID in [
            .all,
            .folder("News"),
            .folder("Blogs"),
            .source("feed-a"),
            .source("feed-b"),
            .source("feed-c"),
            .mastodonHome(accountID: accountID),
        ] {
            #expect(try mark(for: scope, in: context) == target, "\(scope.rawValue)")
        }
    }

    @Test("The children of All Items add up to it")
    func childrenAddUpToAllItems() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.all, to: keys[11], deviceID: device, in: context)
        try context.save()

        let all = try count(.all, in: context)
        let folders = try count(.folder("News"), in: context) + count(.folder("Blogs"), in: context)
        let mastodon = try count(.mastodonHome(accountID: accountID), in: context)
        let feeds = try count(.source("feed-a"), in: context)
            + count(.source("feed-b"), in: context)
            + count(.source("feed-c"), in: context)

        #expect(all == 8)
        #expect(folders + mastodon == all)
        #expect(feeds + mastodon == all)
    }

    @Test("A Mastodon home timeline is never left above All Items")
    func mastodonHomeCannotExceedAllItems() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        // The state the user reported: All Items scrolled, Mastodon Home never opened, so its
        // marker still sits where first sync seeded it — at the bottom, in a fresh store.
        try ThresholdService.setPositionCascading(.all, to: keys[18], deviceID: device, in: context)
        try context.save()

        #expect(try count(.all, in: context) == 1)
        #expect(try count(.mastodonHome(accountID: accountID), in: context) <= count(.all, in: context))
    }

    @Test("Scrolling a folder carries only its own feeds")
    func folderCarriesOnlyItsOwnFeeds() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.folder("News"), to: keys[11], deviceID: device, in: context)
        try context.save()

        #expect(try mark(for: .source("feed-a"), in: context) == keys[11])
        #expect(try mark(for: .source("feed-b"), in: context) == keys[11])
        #expect(try mark(for: .source("feed-c"), in: context) == .distantPast)
        #expect(try mark(for: .mastodonHome(accountID: accountID), in: context) == .distantPast)
    }

    @Test("An unsubscribed feed is left out of the cascade")
    func unsubscribedFeedIsNotCarried() throws {
        let context = try makeContext()
        insertSource(id: "feed-live", folder: "News", in: context)
        insertSource(id: "feed-gone", folder: "News", isSubscribed: false, in: context)
        let keys = insertItems(count: 4, sourceID: "feed-live", folder: "News", startingAt: 1_700_000_000_000, in: context)
        try context.save()

        try ThresholdService.setPositionCascading(.all, to: keys[1], deviceID: device, in: context)
        try context.save()

        #expect(try mark(for: .source("feed-live"), in: context) == keys[1])
        #expect(try mark(for: .source("feed-gone"), in: context) == .distantPast)
    }

    // MARK: - Upward

    @Test("Reading a folder backwards lowers All Items, so no child outgrows its parent")
    func readingBackwardsLowersTheParent() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        // Caught up everywhere.
        try ThresholdService.setPositionCascading(.all, to: keys[19], deviceID: device, in: context)
        try context.save()
        #expect(try count(.all, in: context) == 0)

        // Then go back through one folder.
        try ThresholdService.setPositionCascading(.folder("News"), to: keys[4], deviceID: device, in: context)
        try context.save()

        let news = try count(.folder("News"), in: context)
        #expect(news > 0)
        #expect(try count(.all, in: context) >= news)
        #expect(try mark(for: .all, in: context) == keys[4])
    }

    @Test("Reading a feed backwards lowers both its folder and All Items")
    func readingAFeedBackwardsLowersBothParents() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.all, to: keys[19], deviceID: device, in: context)
        try context.save()

        try ThresholdService.setPositionCascading(.source("feed-a"), to: keys[2], deviceID: device, in: context)
        try context.save()

        let feed = try count(.source("feed-a"), in: context)
        #expect(feed > 0)
        #expect(try count(.folder("News"), in: context) >= feed)
        #expect(try count(.all, in: context) >= count(.folder("News"), in: context))
    }

    @Test("Reading a folder to the top does not drag All Items up with it")
    func readingAFolderForwardsLeavesTheParentAlone() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.all, to: keys[3], deviceID: device, in: context)
        try context.save()
        let before = try count(.all, in: context)

        try ThresholdService.setPositionCascading(.folder("News"), to: keys[19], deviceID: device, in: context)
        try context.save()

        // Finishing one folder says nothing about the others, so the global position must not move.
        #expect(try mark(for: .all, in: context) == keys[3])
        #expect(try count(.all, in: context) == before)
        #expect(try count(.folder("News"), in: context) == 0)
    }

    @Test("A feed with no folder is enclosed by All Items alone")
    func uncategorisedFeedHasOnlyAllItemsAbove() throws {
        let context = try makeContext()
        insertSource(id: "feed-loose", in: context)
        let keys = insertItems(count: 4, sourceID: "feed-loose", startingAt: 1_700_000_000_000, in: context)
        try context.save()

        try ThresholdService.setPositionCascading(.all, to: keys[3], deviceID: device, in: context)
        try context.save()
        try ThresholdService.setPositionCascading(.source("feed-loose"), to: keys[0], deviceID: device, in: context)
        try context.save()

        #expect(try mark(for: .all, in: context) == keys[0])
        #expect(try count(.all, in: context) >= count(.source("feed-loose"), in: context))
    }

    // MARK: - Cross-cutting scopes

    @Test("Read Later and Older Items propagate nothing")
    func crossCuttingScopesStandAlone() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        for scope: ScopeID in [.readLater, .lateArrivals] {
            let written = try ThresholdService.setPositionCascading(
                scope,
                to: keys[9],
                deviceID: device,
                in: context
            )
            #expect(written.map(\.scope) == [scope])
        }
        try context.save()

        #expect(try mark(for: .all, in: context) == .distantPast)
        #expect(try mark(for: .folder("News"), in: context) == .distantPast)
    }

    // MARK: - Repairing an older store

    @Test("The repair pass raises folders and feeds stranded below All Items")
    func repairRaisesStrandedChildren() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        // Exactly the state the user reported, reproduced the way it arose: only `All Items` ever
        // moved, because only `All Items` was ever scrolled.
        try ThresholdService.setPosition(.all, to: keys[16], deviceID: device, in: context)
        try context.save()

        let all = try count(.all, in: context)
        #expect(all == 3)
        #expect(try count(.folder("News"), in: context) > all, "the bug being repaired")

        let repaired = try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        #expect(!repaired.isEmpty)
        #expect(try count(.all, in: context) == all, "the position actually established must survive")
        for scope: ScopeID in [
            .folder("News"),
            .folder("Blogs"),
            .source("feed-a"),
            .source("feed-b"),
            .source("feed-c"),
            .mastodonHome(accountID: accountID),
        ] {
            #expect(try count(scope, in: context) <= all, "\(scope.rawValue)")
        }
    }

    @Test("The repair pass leaves a child that is already ahead alone")
    func repairDoesNotLowerAChildOrItsParent() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPosition(.all, to: keys[4], deviceID: device, in: context)
        try ThresholdService.setPosition(.folder("News"), to: keys[18], deviceID: device, in: context)
        try context.save()

        try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        #expect(try mark(for: .folder("News"), in: context) == keys[18])
        #expect(try mark(for: .all, in: context) == keys[4])
    }

    @Test("The repair pass changes nothing on a store that already obeys the rule")
    func repairIsIdempotent() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.all, to: keys[11], deviceID: device, in: context)
        try context.save()

        #expect(try ThresholdService.reconcileScopeContainment(deviceID: device, in: context).isEmpty)

        try ThresholdService.setPosition(.all, to: keys[15], deviceID: device, in: context)
        try context.save()
        #expect(try !ThresholdService.reconcileScopeContainment(deviceID: device, in: context).isEmpty)
        try context.save()
        #expect(try ThresholdService.reconcileScopeContainment(deviceID: device, in: context).isEmpty)
    }

    @Test("The repair pass only touches this device's own rows")
    func repairLeavesOtherDevicesAlone() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPosition(.all, to: keys[16], deviceID: device, in: context)
        try ThresholdService.setPosition(.folder("News"), to: keys[1], deviceID: "iphone", in: context)
        try context.save()

        let repaired = try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        #expect(repaired.allSatisfy { $0.deviceID == device })

        let iphone = try context.fetch(FetchDescriptor<PositionMark>(
            predicate: #Predicate { $0.deviceID == "iphone" }
        ))
        #expect(iphone.count == 1)
        #expect(iphone.first?.markSortKey == keys[1])
    }

    // MARK: - Repair and staleness

    @Test("A repaired row keeps the time of the position it was copied from")
    func repairInheritsTheParentsTimestamp() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        let reportedAt = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        let all = try ThresholdService.setPosition(.all, to: keys[16], deviceID: device, in: context)
        all.updatedAt = reportedAt
        try context.save()

        let repaired = try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        #expect(!repaired.isEmpty)
        // Not "close to", exactly: the repair is a restatement of that one report, so it has the
        // same time. Any drift towards `.now` is the whole defect.
        #expect(repaired.allSatisfy { $0.updatedAt == reportedAt })
    }

    @Test("Launching a device that is a week behind does not drag a device that is up to date back")
    func repairOnAStaleDeviceDoesNotOutrankAFresherOne() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        // The reported case. This device was last read a week ago and has only ever scrolled
        // `All Items`, so its folders have no row at all — which is what the repair pass is for.
        let stale = try ThresholdService.setPosition(.all, to: keys[4], deviceID: device, in: context)
        stale.updatedAt = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)

        // The other device read this folder an hour ago and is far ahead.
        let fresh = try ThresholdService.setPosition(
            .folder("News"),
            to: keys[18],
            deviceID: "mac-ahead",
            in: context
        )
        fresh.updatedAt = Date(timeIntervalSinceNow: -60 * 60)
        try context.save()

        try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        // Stamped `.now`, the repair would have been the most recently written row in the system
        // and every device would have followed this one backwards to `keys[4]`.
        let position = try ThresholdService.effectivePosition(for: .folder("News"), in: context)
        #expect(position.markSortKey == keys[18])
        #expect(position.deviceID == "mac-ahead")
    }

    @Test("A feed repaired from its folder carries the folder's time, not All Items'")
    func repairCarriesTheTimeOfWhicheverBoundWon() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        let allReportedAt = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        let all = try ThresholdService.setPosition(.all, to: keys[4], deviceID: device, in: context)
        all.updatedAt = allReportedAt

        let folderReportedAt = Date(timeIntervalSinceNow: -60 * 60)
        let folder = try ThresholdService.setPosition(
            .folder("News"),
            to: keys[10],
            deviceID: device,
            in: context
        )
        folder.updatedAt = folderReportedAt
        try context.save()

        try ThresholdService.reconcileScopeContainment(deviceID: device, in: context)
        try context.save()

        // `feed-a` sits in `News`, so the folder is the binding floor and the folder's report is
        // what is being restated. Pairing the folder's key with `All Items`' timestamp would
        // backdate a position by a week.
        let feed = try ThresholdService.effectivePosition(for: .source("feed-a"), in: context)
        #expect(feed.markSortKey == keys[10])
        #expect(feed.updatedAt == folderReportedAt)

        // The Mastodon timeline is in no folder, so it is repaired from `All Items` and keeps that
        // report's time.
        let home = try ThresholdService.effectivePosition(
            for: .mastodonHome(accountID: accountID),
            in: context
        )
        #expect(home.markSortKey == keys[4])
        #expect(home.updatedAt == allReportedAt)
    }

    // MARK: - Sync

    @Test("Every row the cascade writes comes back for the outbox")
    func everyWrittenRowIsReturned() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        let written = try ThresholdService.setPositionCascading(
            .all,
            to: keys[11],
            deviceID: device,
            in: context
        )
        try context.save()

        // A row missing from the return value would persist locally and never be pushed, so the
        // other device would keep counting against a position this one had already moved past.
        let stored = try context.fetch(FetchDescriptor<PositionMark>())
        #expect(Set(written.map(\.key)) == Set(stored.map(\.key)))
        #expect(written.count == 7)
        #expect(written.allSatisfy { $0.markSortKey == keys[11] })
    }

    @Test("Cascading twice reuses the same rows rather than inserting duplicates")
    func cascadingIsIdempotentPerScope() throws {
        let context = try makeContext()
        let keys = try makeTree(in: context)

        try ThresholdService.setPositionCascading(.all, to: keys[5], deviceID: device, in: context)
        try context.save()
        try ThresholdService.setPositionCascading(.all, to: keys[12], deviceID: device, in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 7)
        #expect(try mark(for: .folder("News"), in: context) == keys[12])
    }
}
