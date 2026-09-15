import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// "The next item" has to mean the same thing to a swipe on iPhone as to the down arrow on a Mac,
/// and it has to respect whichever list the reader is actually in.
@Suite("TimelineNavigator")
struct TimelineNavigatorTests {

    private let accountID = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    @discardableResult
    private func insert(
        _ id: String,
        millis: Int64,
        in context: ModelContext,
        sourceID: String = "feed-a",
        folderName: String? = "News",
        isFilteredOut: Bool = false,
        isAccountEnabled: Bool = true
    ) -> CachedItem {
        let key = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: sourceID,
            accountID: accountID,
            folderName: folderName,
            kind: .article,
            title: id,
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: key,
            ingestKey: key,
            isFilteredOut: isFilteredOut,
            isAccountEnabled: isAccountEnabled
        )
        context.insert(item)
        return item
    }

    private func seed(_ context: ModelContext) throws {
        for index in 1...5 {
            insert("item-\(index)", millis: 1_700_000_000_000 + Int64(index) * 1_000, in: context)
        }
        try context.save()
    }

    @Test("Older and newer move in opposite directions")
    func movesBothWays() throws {
        let context = try makeContext()
        try seed(context)

        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .all, direction: .older, context: context
        ) == "item-2")

        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .all, direction: .newer, context: context
        ) == "item-4")
    }

    @Test("The ends of the list report nothing rather than wrapping")
    func stopsAtTheEnds() throws {
        let context = try makeContext()
        try seed(context)

        // Wrapping would make a swipe at the bottom look like the list had reordered itself.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-5", in: .all, direction: .newer, context: context
        ) == nil)
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-1", in: .all, direction: .older, context: context
        ) == nil)
    }

    @Test("Navigation stays inside the scope")
    func staysInScope() throws {
        let context = try makeContext()
        try seed(context)
        // An item that sorts between two of the others but belongs elsewhere.
        insert("other", millis: 1_700_000_003_500, in: context, sourceID: "feed-b", folderName: "Tech")
        try context.save()

        // Whole-store adjacency would land here; the folder's own order must not.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .all, direction: .newer, context: context
        ) == "other")
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .folder("News"), direction: .newer, context: context
        ) == "item-4")
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .source("feed-a"), direction: .newer, context: context
        ) == "item-4")
    }

    @Test("A filtered item is skipped, not landed on")
    func skipsFilteredItems() throws {
        let context = try makeContext()
        try seed(context)
        insert("hidden", millis: 1_700_000_003_500, in: context, isFilteredOut: true)
        try context.save()

        // It is not in the list, so swiping onto it would open something the reader cannot see.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .all, direction: .newer, context: context
        ) == "item-4")
    }

    @Test("A disabled account's items are skipped too")
    func skipsDisabledAccounts() throws {
        let context = try makeContext()
        try seed(context)
        insert("off", millis: 1_700_000_003_500, in: context, isAccountEnabled: false)
        try context.save()

        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .all, direction: .newer, context: context
        ) == "item-4")
    }

    @Test("An unknown item has no neighbours")
    func unknownItem() throws {
        let context = try makeContext()
        try seed(context)

        // A pruned item can still be the selection when the swipe arrives.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "gone", in: .all, direction: .newer, context: context
        ) == nil)
    }

    @Test("Read Later has no adjacency of this kind")
    func readLaterHasNone() throws {
        let context = try makeContext()
        try seed(context)

        // Its list is `ReadLaterEntry`, not `CachedItem`, so there is nothing here to walk.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "item-3", in: .readLater, direction: .newer, context: context
        ) == nil)
    }
}
