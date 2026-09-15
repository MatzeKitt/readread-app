import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The Filtered Items scope.
///
/// It is the one scope whose predicate runs the *other* way — every other list excludes hidden
/// items and this one is made of them — so the two things worth pinning down are that it shows what
/// it should and that it stays out of the machinery that moves reading positions around.
@Suite("Filtered scope")
struct FilteredScopeTests {

    private let accountID = UUID()

    private func makeContext(hidden: Int, visible: Int) throws -> ModelContext {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        var offset = 0
        for _ in 0..<hidden {
            insert(offset: offset, isFilteredOut: true, in: context)
            offset += 1
        }
        for _ in 0..<visible {
            insert(offset: offset, isFilteredOut: false, in: context)
            offset += 1
        }
        try context.save()
        return context
    }

    private func insert(
        offset: Int,
        isFilteredOut: Bool,
        isAccountEnabled: Bool = true,
        in context: ModelContext
    ) {
        let millis = 1_700_000_000_000 + Int64(offset) * 1_000
        let key = SortKey(millis: millis, id: "item-\(offset)")
        let item = CachedItem(
            id: "item-\(offset)",
            sourceID: "feed/1",
            accountID: accountID,
            kind: .article,
            title: "Item \(offset)",
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: key,
            ingestKey: key
        )
        item.isFilteredOut = isFilteredOut
        item.isAccountEnabled = isAccountEnabled
        context.insert(item)
    }

    private func displayCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: ScopeQuery.displayPredicate(for: .filtered))
        )
    }

    @Test("The list is exactly what the rules are hiding")
    func showsOnlyHiddenItems() throws {
        let context = try makeContext(hidden: 3, visible: 5)

        #expect(try displayCount(in: context) == 3)
    }

    /// A disabled account withholds its items everywhere. Showing them here would make switching an
    /// account off look like it had filtered its items instead.
    @Test("Items from a disabled account stay out of it")
    func disabledAccountsAreExcluded() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        insert(offset: 0, isFilteredOut: true, in: context)
        insert(offset: 1, isFilteredOut: true, isAccountEnabled: false, in: context)
        try context.save()

        #expect(try displayCount(in: context) == 1)
    }

    /// The count is the size of the list, not "how many you have not looked at": there is no
    /// position here to have looked past.
    @Test("The count is a total and ignores any marker")
    func countIsATotal() throws {
        let context = try makeContext(hidden: 4, visible: 2)
        #expect(try ThresholdService.newerCount(for: .filtered, in: context) == 4)

        // Move a position as far as it will go. Every other scope would read zero after this.
        if let newest = try ThresholdService.newestItem(for: .all, in: context) {
            try ThresholdService.setPositionCascading(
                .all,
                to: newest.sortKey,
                deviceID: "device",
                in: context
            )
            try context.save()
        }

        #expect(try ThresholdService.newerCount(for: .filtered, in: context) == 4)
    }

    /// It is a cross-cutting view, not a place in the tree, so a scroll anywhere else must not
    /// touch it and it must not carry anything to anyone.
    @Test("It neither contains nor is contained by any other scope")
    func propagatesNoPosition() throws {
        let context = try makeContext(hidden: 1, visible: 1)

        #expect(try ThresholdService.containedScopes(of: .filtered, in: context).isEmpty)
        #expect(try ThresholdService.enclosingScopes(of: .filtered, in: context).isEmpty)
        #expect(try ThresholdService.containedScopes(of: .all, in: context).contains(.filtered) == false)
    }

    @Test("Nothing in it is offered as a late arrival")
    func hasNoLateArrivals() {
        #expect(ScopeQuery.lateArrivalPredicate(for: .filtered) == nil)
    }

    /// The string form keys `PositionMark` and travels through the sync endpoint, so it has to
    /// round-trip exactly — and must not collide with a folder actually named "filtered".
    @Test("The scope id round-trips")
    func roundTrips() {
        #expect(ScopeID.filtered.rawValue == "filtered")
        #expect(ScopeID(rawValue: "filtered") == .filtered)
        #expect(ScopeID(rawValue: "folder:filtered") == .folder("filtered"))
    }

    @Test("It addresses no single source")
    func hasNoSourceID() {
        #expect(SourceIdentifier.sourceID(for: .filtered) == nil)
    }
}
