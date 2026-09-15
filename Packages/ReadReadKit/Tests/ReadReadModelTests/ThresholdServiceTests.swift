import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Behaviour tests against a real in-memory store, not against the reduction function in
/// isolation. The predicates are half the logic and they only exist once compiled by SwiftData, so
/// unit-testing the Swift side alone would miss exactly the bugs that matter.
@Suite("ThresholdService")
struct ThresholdServiceTests {

    // MARK: - Fixtures

    private let accountID = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    /// Inserts `count` items one second apart, oldest first, so index 0 is the oldest.
    @discardableResult
    private func insertItems(
        count: Int,
        sourceID: String,
        folder: String? = nil,
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
                ingestKey: key
            ))
            return key
        }
    }

    private func insertSource(
        id: String,
        folder: String? = nil,
        in context: ModelContext
    ) {
        context.insert(CachedSource(
            id: id,
            accountID: accountID,
            kind: .article,
            title: id,
            folderName: folder
        ))
    }

    /// Sets a position and back-dates it, so ordering between devices is explicit.
    private func setPosition(
        _ scope: ScopeID,
        to key: SortKey,
        deviceID: String,
        at date: Date,
        in context: ModelContext
    ) throws {
        try ThresholdService.setPosition(scope, to: key, deviceID: deviceID, in: context)

        let markKey = PositionMark.key(scope: scope, deviceID: deviceID)
        var descriptor = FetchDescriptor<PositionMark>(predicate: #Predicate { $0.key == markKey })
        descriptor.fetchLimit = 1
        try context.fetch(descriptor).first?.updatedAt = date
    }

    // MARK: - Counts

    @Test("An untouched scope counts every item")
    func untouchedScopeCountsEverything() throws {
        let context = try makeContext()
        insertItems(count: 7, sourceID: "feed-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 7)
    }

    @Test("Advancing the marker reduces the count to the items above it")
    func advancingReducesCount() throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, sourceID: "feed-a", in: context)
        try context.save()

        // Read up to index 6, leaving 7, 8 and 9 above the marker.
        try ThresholdService.setPosition(.all, to: keys[6], deviceID: "device-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)
    }

    @Test("Marking the newest item read empties the count")
    func markingNewestEmptiesCount() throws {
        let context = try makeContext()
        let keys = insertItems(count: 5, sourceID: "feed-a", in: context)
        try context.save()

        try ThresholdService.setPosition(.all, to: keys.last!, deviceID: "device-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)
    }

    @Test("Filtered items never count")
    func filteredItemsDoNotCount() throws {
        let context = try makeContext()
        insertItems(count: 5, sourceID: "feed-a", in: context)
        context.insert(CachedItem(
            id: "sponsored",
            sourceID: "feed-a",
            accountID: accountID,
            kind: .article,
            title: "Sponsored",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_700_000_100_000, id: "sponsored"),
            ingestKey: SortKey(millis: 1_700_000_100_000, id: "sponsored"),
            isFilteredOut: true
        ))
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 5)
    }

    /// Each scope carries its own marker. Scrolling the unified timeline must not silently mark an
    /// individual feed caught up — that independence is the whole reason positions are per-scope.
    @Test("Scopes track independently")
    func scopesTrackIndependently() throws {
        let context = try makeContext()
        insertSource(id: "feed-a", in: context)
        insertSource(id: "feed-b", in: context)
        insertItems(count: 4, sourceID: "feed-a", in: context)
        let keysB = insertItems(count: 6, sourceID: "feed-b", startingAt: 1_700_000_100_000, in: context)
        try context.save()

        try ThresholdService.setPosition(.source("feed-b"), to: keysB.last!, deviceID: "device-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .source("feed-b"), in: context) == 0)
        #expect(try ThresholdService.newerCount(for: .source("feed-a"), in: context) == 4)
        // The unified timeline's own marker was never moved, so it still sees all ten.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 10)
    }

    @Test("A folder counts only the items of its own feeds")
    func folderCountsOwnFeedsOnly() throws {
        let context = try makeContext()
        insertSource(id: "feed-a", folder: "News", in: context)
        insertSource(id: "feed-b", folder: "News", in: context)
        insertSource(id: "feed-c", folder: "Tech", in: context)
        insertItems(count: 3, sourceID: "feed-a", folder: "News", in: context)
        insertItems(count: 4, sourceID: "feed-b", folder: "News", in: context)
        insertItems(count: 5, sourceID: "feed-c", folder: "Tech", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .folder("News"), in: context) == 7)
        #expect(try ThresholdService.newerCount(for: .folder("Tech"), in: context) == 5)
    }

    @Test("An empty or unknown folder counts zero rather than everything")
    func unknownFolderCountsZero() throws {
        let context = try makeContext()
        insertSource(id: "feed-a", folder: "News", in: context)
        insertItems(count: 3, sourceID: "feed-a", folder: "News", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .folder("Nonexistent"), in: context) == 0)
    }

    @Test("A Mastodon home scope resolves to its underlying source")
    func mastodonHomeResolvesToSource() throws {
        let context = try makeContext()
        let sourceID = SourceIdentifier.mastodonHome(accountID: accountID)
        insertSource(id: sourceID, in: context)
        insertItems(count: 4, sourceID: sourceID, in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .mastodonHome(accountID: accountID), in: context) == 4)
    }

    @Test("Read Later carries its own position")
    func readLaterHasItsOwnPosition() throws {
        let context = try makeContext()
        var keys: [SortKey] = []
        for offset in 0..<4 {
            let millis = Int64(1_700_000_000_000 + offset * 1_000)
            let key = SortKey(millis: millis, id: "saved-\(offset)")
            keys.append(key)
            context.insert(ReadLaterEntry(
                itemID: "saved-\(offset)",
                sourceID: "feed-a",
                accountID: accountID,
                kind: .article,
                title: "Saved \(offset)",
                sourceTitle: "Feed A",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key
            ))
        }
        try context.save()

        #expect(try ThresholdService.newerCount(for: .readLater, in: context) == 4)

        try ThresholdService.setPosition(.readLater, to: keys[1], deviceID: "device-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .readLater, in: context) == 2)
    }

    // MARK: - Position movement

    /// The behaviour the whole model turns on. An earlier design made the position a high-water
    /// mark that could only move forward; it could not express the count, because a reader who had
    /// once reached the top stayed "up to date" no matter how far back down they scrolled.
    @Test("Scrolling back down moves the position back and raises the count")
    func positionMovesBackwards() throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, sourceID: "feed-a", in: context)
        try context.save()

        try ThresholdService.setPosition(.all, to: keys[9], deviceID: "device-a", in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)

        // Back down the timeline: seven items are above the fold again, and must be counted.
        try ThresholdService.setPosition(.all, to: keys[2], deviceID: "device-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 7)
    }

    @Test("The count is the number of items above the position", arguments: [0, 3, 5, 9])
    func countMatchesItemsAbove(index: Int) throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, sourceID: "feed-a", in: context)
        try context.save()

        try ThresholdService.setPosition(.all, to: keys[index], deviceID: "device-a", in: context)
        try context.save()

        // `keys` is oldest-first, so the items above `keys[index]` are the ones after it.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 9 - index)
    }

    /// The multi-device case the per-device row design exists for. The rule is *most recent*, not
    /// furthest: a position is where the reader is, so the newest report of it is the truth.
    @Test("The most recently written device position wins")
    func mostRecentDeviceWins() throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, sourceID: "feed-a", in: context)
        try context.save()

        try setPosition(.all, to: keys[7], deviceID: "mac", at: .now.addingTimeInterval(-60), in: context)
        try setPosition(.all, to: keys[3], deviceID: "iphone", at: .now, in: context)
        try context.save()

        // Two rows exist, and the later one governs even though it is further back.
        #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 2)
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 6)

        // The Mac is picked up again and moves: it becomes authoritative in turn.
        try ThresholdService.setPosition(.all, to: keys[8], deviceID: "mac", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 1)
    }

    /// Writing is unconditional for exactly this case: the position has not moved, but *being here
    /// now* is what has to win. Skipping the write would leave the other device's later row
    /// governing, so this device's own screen would show someone else's count.
    @Test("Returning to a position already recorded reclaims authority")
    func rewritingSamePositionReclaimsAuthority() throws {
        let context = try makeContext()
        let keys = insertItems(count: 10, sourceID: "feed-a", in: context)
        try context.save()

        try setPosition(.all, to: keys[2], deviceID: "mac", at: .now.addingTimeInterval(-60), in: context)
        try setPosition(.all, to: keys[8], deviceID: "iphone", at: .now, in: context)
        try context.save()
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 1)

        // The Mac scrolls back to precisely where it already was.
        try ThresholdService.setPosition(.all, to: keys[2], deviceID: "mac", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 7)
    }

    @Test("Setting a position creates exactly one row per device and scope")
    func setPositionIsIdempotentPerDeviceAndScope() throws {
        let context = try makeContext()
        let keys = insertItems(count: 5, sourceID: "feed-a", in: context)
        try context.save()

        for key in keys {
            try ThresholdService.setPosition(.all, to: key, deviceID: "device-a", in: context)
        }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 1)
    }

    // MARK: - Late arrivals

    @Test("Late arrivals are counted separately from the main count")
    func lateArrivalsCountedSeparately() throws {
        let context = try makeContext()
        let keys = insertItems(count: 5, sourceID: "feed-a", in: context)
        try context.save()
        try ThresholdService.setPosition(.all, to: keys.last!, deviceID: "device-a", in: context)
        try context.save()

        // A back-dated item arrives below the marker: chronological ordering puts it out of sight,
        // so it must not inflate the main count but must still be discoverable.
        let backDated = SortKey(millis: 1_600_000_000_000, id: "back-dated")
        context.insert(CachedItem(
            id: "back-dated",
            sourceID: "feed-a",
            accountID: accountID,
            kind: .article,
            title: "From the archive",
            publishedAt: Date(millisecondsSinceEpoch: 1_600_000_000_000),
            sortKey: backDated,
            ingestKey: SortKey(millis: 1_700_000_900_000, id: "back-dated"),
            arrivedLate: true
        ))
        try context.save()

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 0)
        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 1)
    }

    // MARK: - Folder denormalisation

    /// The hazard that comes with denormalising `folderName` onto items: if it is not kept in
    /// step, a feed's existing items stay attached to the old folder while new ones appear in the
    /// right place — which looks like a sync bug rather than a stale copy.
    @Test("Moving a feed between folders rewrites its existing items")
    func movingFeedBetweenFoldersRewritesItems() throws {
        let context = try makeContext()
        insertSource(id: "feed-a", folder: "News", in: context)
        insertItems(count: 4, sourceID: "feed-a", folder: "News", in: context)
        insertSource(id: "feed-b", folder: "Tech", in: context)
        insertItems(count: 2, sourceID: "feed-b", folder: "Tech", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .folder("News"), in: context) == 4)

        try ThresholdService.updateFolderName("Tech", forSourceID: "feed-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .folder("News"), in: context) == 0)
        #expect(try ThresholdService.newerCount(for: .folder("Tech"), in: context) == 6)
    }

    @Test("Clearing a feed's folder detaches its items from the old folder")
    func clearingFolderDetachesItems() throws {
        let context = try makeContext()
        insertSource(id: "feed-a", folder: "News", in: context)
        insertItems(count: 3, sourceID: "feed-a", folder: "News", in: context)
        try context.save()

        try ThresholdService.updateFolderName(nil, forSourceID: "feed-a", in: context)
        try context.save()

        #expect(try ThresholdService.newerCount(for: .folder("News"), in: context) == 0)
        // Still present in the unified timeline — detached from a folder, not deleted.
        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)
    }

    @Test("A filtered late arrival is not surfaced")
    func filteredLateArrivalIsNotSurfaced() throws {
        let context = try makeContext()
        context.insert(CachedItem(
            id: "back-dated",
            sourceID: "feed-a",
            accountID: accountID,
            kind: .article,
            title: "Sponsored archive post",
            publishedAt: Date(millisecondsSinceEpoch: 1_600_000_000_000),
            sortKey: SortKey(millis: 1_600_000_000_000, id: "back-dated"),
            ingestKey: SortKey(millis: 1_700_000_900_000, id: "back-dated"),
            arrivedLate: true,
            isFilteredOut: true
        ))
        try context.save()

        #expect(try ThresholdService.lateArrivalCount(for: .all, in: context) == 0)
    }
}
