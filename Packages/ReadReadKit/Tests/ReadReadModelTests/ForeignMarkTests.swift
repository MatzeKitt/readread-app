import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The one-item drift a synced position used to open with.
///
/// An item's sort key is `<millis>|<item id>`, and the item id carries the account's UUID — which
/// each device generates for itself. The timestamp half is a server value and agrees everywhere;
/// the id half never does. Since the position is compared with `>`, the disagreement lands squarely
/// on the item the marker names, and which side of the marker it falls on is decided by how the two
/// devices' UUIDs happen to compare as strings. Deterministic, and therefore wrong every single time
/// for a given pair of devices: the list opened one item too far down and the item the reader had
/// actually stopped on was left counting as new.
///
/// Both directions are tested against the same store, because the property that matters is not
/// "the count is 5" — it is that **the count does not depend on which device wrote the mark.**
@Suite("Foreign position marks")
struct ForeignMarkTests {

    /// Chosen so `localAccount` sorts *above* `aheadAccount` and *below* `behindAccount` as a
    /// string. Those two orderings are the two halves of the bug.
    private let localAccount = "44444444-4444-4444-4444-444444444444"
    private let aheadAccount = "11111111-1111-1111-1111-111111111111"
    private let behindAccount = "99999999-9999-9999-9999-999999999999"

    private let base: Int64 = 1_700_000_000_000

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    /// Ten items a second apart, newest last, stored the way ingest stores them: the id carries
    /// this device's account UUID.
    private func insertItems(in context: ModelContext) -> [String] {
        (0..<10).map { offset in
            let millis = base + Int64(offset) * 1_000
            let providerID = "entry\(offset)"
            let id = "freshrss:\(localAccount):\(providerID)"
            let key = SortKey(millis: millis, id: id)
            context.insert(CachedItem(
                id: id,
                sourceID: "freshrss:\(localAccount):feed/1",
                accountID: UUID(uuidString: localAccount)!,
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key
            ))
            return providerID
        }
    }

    /// The key another device would have written for the same article.
    private func foreignMark(forOffset offset: Int, account: String) -> SortKey {
        SortKey(
            millis: base + Int64(offset) * 1_000,
            id: "freshrss:\(account):entry\(offset)"
        )
    }

    private func writeMark(_ key: SortKey, deviceID: String, in context: ModelContext) throws {
        let mark = PositionMark(scope: .all, deviceID: deviceID)
        mark.markSortKey = key
        mark.updatedAt = .now
        context.insert(mark)
        try context.save()
    }

    /// The half that drifted, and the shape of it exactly as reported.
    ///
    /// Offset 6 is the seventh-oldest of ten, so three items are newer and the marked item sits at
    /// row 3. When the writing device's account UUID sorts *below* this one's, the local key for the
    /// very same article sorts *above* the mark — so the article counts as newer than itself. The
    /// count came out as four, the position resolved to the item below it, and the item the reader
    /// had stopped on was left counting as new.
    @Test("A mark from a device whose account id sorts lower counts the same as a local one")
    func lowerSortingAccountDoesNotDrift() throws {
        let context = try makeContext()
        insertItems(in: context)
        try writeMark(foreignMark(forOffset: 6, account: aheadAccount), deviceID: "other", in: context)

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)
        let item = try ThresholdService.itemAtPosition(for: .all, in: context)
        #expect(item?.id == "freshrss:\(localAccount):entry6")
    }

    /// The half that happened to be right all along: a UUID sorting above this device's leaves the
    /// local key below the mark, which is where an exact match would also have put it. Kept as a
    /// test because it is the same code path, and because a fix that repaired one direction by
    /// breaking the other would look like a fix.
    @Test("A mark from a device whose account id sorts higher does not drift either")
    func higherSortingAccountDoesNotDrift() throws {
        let context = try makeContext()
        insertItems(in: context)
        try writeMark(foreignMark(forOffset: 6, account: behindAccount), deviceID: "other", in: context)

        #expect(try ThresholdService.newerCount(for: .all, in: context) == 3)
        let item = try ThresholdService.itemAtPosition(for: .all, in: context)
        #expect(item?.id == "freshrss:\(localAccount):entry6")
    }

    /// The whole point, stated as one assertion.
    @Test("The count does not depend on which device wrote the mark")
    func countIsIndependentOfTheWritingDevice() throws {
        for account in [localAccount, aheadAccount, behindAccount] {
            let context = try makeContext()
            insertItems(in: context)
            try writeMark(foreignMark(forOffset: 2, account: account), deviceID: "device", in: context)

            #expect(try ThresholdService.newerCount(for: .all, in: context) == 7)
        }
    }

    /// A local mark must be left exactly as it is: it is already in this store's key space, and
    /// this is the path every count on the device takes.
    @Test("A mark this store already agrees with is returned untouched")
    func localMarkIsUntouched() throws {
        let context = try makeContext()
        insertItems(in: context)
        let key = SortKey(millis: base + 6_000, id: "freshrss:\(localAccount):entry6")

        #expect(try ThresholdService.localisedMark(key, in: context) == key)
    }

    /// The article is not in this store — pruned, filtered out of every scope, or belonging to an
    /// account this device does not have. Guessing would be worse than the drift, so the mark is
    /// returned as it came and the timestamp half still puts it in roughly the right place.
    @Test("An unplaceable mark is returned unchanged")
    func unplaceableMarkIsUnchanged() throws {
        let context = try makeContext()
        insertItems(in: context)
        let missing = SortKey(millis: base + 6_000, id: "freshrss:\(behindAccount):entry-nobody-has")

        #expect(try ThresholdService.localisedMark(missing, in: context) == missing)
    }

    /// `.distantPast` is the position of a scope nobody has read, and it reaches this code on every
    /// count of every such scope.
    @Test("Sentinels are left alone")
    func sentinelsAreLeftAlone() throws {
        let context = try makeContext()
        insertItems(in: context)

        #expect(try ThresholdService.localisedMark(.distantPast, in: context) == .distantPast)
        #expect(try ThresholdService.localisedMark(.distantFuture, in: context) == .distantFuture)
    }

    /// The property the timeline's adopt-a-remote-position logic has to be built around.
    ///
    /// `localisedMark` is a **store lookup**, so its answer for one unchanged mark moves as the
    /// store fills: before the article arrives there is nothing to translate to and the mark comes
    /// back as it was, and once ingest brings the article in the same mark starts resolving to the
    /// local row's key. Both answers are right for their moment.
    ///
    /// It is the *change* that matters, and it is why the open timeline cannot treat this value as
    /// the identity of a report. It did, and so an ordinary refresh looked exactly like another
    /// device reporting a new position — which scrolled the list out from under whoever was reading
    /// it. See `ForeignPosition` in `TimelineView`.
    @Test("The same mark localises differently once its article lands")
    func translationMovesWhenTheArticleArrives() throws {
        let context = try makeContext()
        insertItems(in: context)

        // Offset 10 is one second newer than the ten items above, and no device has it yet.
        let reported = foreignMark(forOffset: 10, account: behindAccount)
        #expect(try ThresholdService.localisedMark(reported, in: context) == reported)

        let millis = base + 10_000
        let id = "freshrss:\(localAccount):entry10"
        let local = SortKey(millis: millis, id: id)
        context.insert(CachedItem(
            id: id,
            sourceID: "freshrss:\(localAccount):feed/1",
            accountID: UUID(uuidString: localAccount)!,
            kind: .article,
            title: "Item 10",
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: local,
            ingestKey: local
        ))
        try context.save()

        // Same mark, same call, different answer — with nothing having been reported in between.
        #expect(try ThresholdService.localisedMark(reported, in: context) == local)
        #expect(local != reported)
    }

    @Test("An item id splits into its stable part")
    func stableKeyIsTheProviderPart() {
        #expect(ThresholdService.stableItemKey(in: "freshrss:\(localAccount):deadbeef") == "deadbeef")
        #expect(ThresholdService.stableItemKey(in: "mastodon:\(localAccount):115123") == "115123")
        // A provider id carrying colons of its own survives whole.
        #expect(
            ThresholdService.stableItemKey(in: "freshrss:\(localAccount):tag:reader/item/1")
                == "tag:reader/item/1"
        )
        #expect(ThresholdService.stableItemKey(in: "freshrss:only-two-parts") == nil)
    }
}
