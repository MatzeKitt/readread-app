import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Searching the cache.
///
/// What a search may find is the question here as much as what it matches: a search replaces the
/// list the reader is looking at, so it must not reach anything that list would not have shown —
/// another feed, a filtered item, a switched-off account's posts.
@Suite("Search")
struct SearchTests {

    private let accountID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
    private let otherAccountID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!

    private var sourceID: String { "freshrss:\(accountID):feed/1" }
    private var otherSourceID: String { "freshrss:\(accountID):feed/2" }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    @discardableResult
    private func insert(
        _ id: String,
        in context: ModelContext,
        title: String? = nil,
        html: String = "",
        authorName: String? = nil,
        sourceID: String? = nil,
        accountID: UUID? = nil,
        millis: Int64 = 1_700_000_000_000,
        isFilteredOut: Bool = false,
        isAccountEnabled: Bool = true
    ) -> CachedItem {
        let key = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: sourceID ?? self.sourceID,
            accountID: accountID ?? self.accountID,
            folderName: "News",
            kind: .article,
            title: title ?? id,
            authorName: authorName,
            contentHTML: html,
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: key,
            ingestKey: key,
            isFilteredOut: isFilteredOut,
            isAccountEnabled: isAccountEnabled
        )
        context.insert(item)
        return item
    }

    private func results(
        _ text: String,
        in scope: ScopeID = .all,
        context: ModelContext
    ) throws -> [String] {
        let query = try #require(SearchQuery(text))
        let descriptor = FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.searchPredicate(for: scope, matching: query),
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.id)
    }

    // MARK: - The query

    @Test("Nothing to search for is no query at all")
    func emptyQueryIsNil() {
        #expect(SearchQuery("") == nil)
        #expect(SearchQuery("   \n\t ") == nil)
    }

    @Test("Terms are folded, split on whitespace and de-duplicated")
    func termsAreFolded() throws {
        let query = try #require(SearchQuery("  Über  STRASSE über "))
        #expect(query.terms == ["uber", "strasse"])
    }

    @Test("Folding ignores case, accents and width, and writes ß out")
    func folding() {
        #expect(SearchText.fold("Über Straße ÉCOLE Ｆｕｌｌ") == "uber strasse ecole full")
    }

    // MARK: - What matches

    @Test("Every term must appear, in any order")
    func everyTermMustMatch() throws {
        let context = try makeContext()
        insert("both", in: context, title: "Actors in Swift")
        insert("one", in: context, title: "Swift on the server")
        try context.save()

        #expect(try results("swift actors", context: context) == ["both"])
        #expect(try results("SWIFT", context: context).sorted() == ["both", "one"])
    }

    @Test("A word far into the body is found, and markup is not")
    func matchesWholeBodyNotMarkup() throws {
        let context = try makeContext()
        // Well past the 320 characters the excerpt keeps, which is the point of the column.
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        insert(
            "deep",
            in: context,
            html: "<p class=\"lead\">\(filler)</p><p>Zebrafinken &auml;ndern ihr Lied.</p>"
        )
        try context.save()

        #expect(try results("zebrafinken", context: context) == ["deep"])
        // Spelled as an entity in the feed, found by the word it spells.
        #expect(try results("ändern", context: context) == ["deep"])
        #expect(try results("class", context: context).isEmpty)
        #expect(try results("lead", context: context).isEmpty)
    }

    @Test("The author is searchable")
    func matchesAuthor() throws {
        let context = try makeContext()
        insert("a", in: context, authorName: "Ada Lovelace")
        try context.save()

        #expect(try results("lovelace", context: context) == ["a"])
    }

    @Test("Results come newest first, like the timeline")
    func resultsAreOrdered() throws {
        let context = try makeContext()
        insert("old", in: context, title: "Match", millis: 1_700_000_000_000)
        insert("new", in: context, title: "Match", millis: 1_700_000_100_000)
        try context.save()

        #expect(try results("match", context: context) == ["new", "old"])
    }

    // MARK: - What a search may reach

    @Test("A feed's search finds only that feed's items")
    func scopedToSource() throws {
        let context = try makeContext()
        insert("here", in: context, title: "Match")
        insert("there", in: context, title: "Match", sourceID: otherSourceID)
        try context.save()

        #expect(try results("match", in: .source(sourceID), context: context) == ["here"])
        #expect(try results("match", in: .all, context: context).sorted() == ["here", "there"])
    }

    @Test("Filtered items stay out, except when searching Filtered Items")
    func filteredItems() throws {
        let context = try makeContext()
        insert("shown", in: context, title: "Match")
        insert("hidden", in: context, title: "Match", isFilteredOut: true)
        try context.save()

        #expect(try results("match", in: .all, context: context) == ["shown"])
        #expect(try results("match", in: .filtered, context: context) == ["hidden"])
    }

    @Test("A switched-off account's items stay out")
    func disabledAccount() throws {
        let context = try makeContext()
        insert("on", in: context, title: "Match")
        insert("off", in: context, title: "Match", accountID: otherAccountID, isAccountEnabled: false)
        try context.save()

        #expect(try results("match", in: .all, context: context) == ["on"])
        #expect(try results("match", in: .filtered, context: context).isEmpty)
    }

    @Test("Next and previous walk the results, not the scope")
    func adjacencyWithinResults() throws {
        let context = try makeContext()
        insert("a", in: context, title: "Match", millis: 1_700_000_300_000)
        insert("b", in: context, title: "Other", millis: 1_700_000_200_000)
        insert("c", in: context, title: "Match", millis: 1_700_000_100_000)
        try context.save()

        let query = try #require(SearchQuery("match"))
        #expect(try TimelineNavigator.adjacentItemID(
            to: "a", in: .all, matching: query, direction: .older, context: context
        ) == "c")
        #expect(try TimelineNavigator.adjacentItemID(
            to: "c", in: .all, matching: query, direction: .newer, context: context
        ) == "a")
        // Without a query it is the scope's own order, as before.
        #expect(try TimelineNavigator.adjacentItemID(
            to: "a", in: .all, direction: .older, context: context
        ) == "b")
    }

    // MARK: - Keeping the column current

    @Test("A re-ingested item is searched by its new words, not its old ones")
    func reingestRewritesSearchText() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)

        func ingested(_ html: String) -> IngestedItem {
            IngestedItem(
                id: "a",
                sourceID: sourceID,
                accountID: accountID,
                kind: .article,
                title: "Title",
                contentHTML: html,
                publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
                sortKey: SortKey(millis: 1_700_000_000_000, id: "a"),
                ingestKey: SortKey(millis: 1_700_000_000_000, id: "a"),
                providerID: "1"
            )
        }

        for html in ["<p>Before the correction.</p>", "<p>After the correction.</p>"] {
            _ = try await sink.commit(
                items: [ingested(html)],
                accountID: accountID,
                streamKey: "reading-list",
                resumeContinuation: "",
                pendingHighestSeenID: "1"
            )
        }

        let context = ModelContext(container)
        #expect(try results("after", context: context) == ["a"])
        #expect(try results("before", context: context).isEmpty)
    }

    @Test("Rows written before the column existed are filled in, and only once")
    func backfill() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let item = insert("a", in: context, html: "<p>Backfilled words.</p>")
        // What a migrated store holds: the column exists, with nothing in it.
        item.searchText = nil
        try context.save()
        #expect(try results("backfilled", context: context).isEmpty)

        let backfill = SearchTextBackfill(modelContainer: container)
        #expect(try await backfill.fillMissing() == 1)
        #expect(try await backfill.fillMissing() == 0)

        #expect(try results("backfilled", context: ModelContext(container)) == ["a"])
    }

    // MARK: - Read Later

    private func readLater(_ text: String, context: ModelContext) throws -> [String] {
        let query = try #require(SearchQuery(text))
        let descriptor = FetchDescriptor<ReadLaterEntry>(
            predicate: ReadLaterService.searchPredicate(matching: query)
        )
        return try context.fetch(descriptor).map(\.itemID).sorted()
    }

    @Test("A saved item is searched by its whole body, archived or not")
    func readLaterSearchesWholeBody() throws {
        let context = try makeContext()
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        let item = insert("a", in: context, title: "Saved", html: "<p>\(filler) Nachtigall</p>")
        try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: false, in: context)
        insert("b", in: context, title: "Not saved", html: "<p>Nachtigall</p>")
        try context.save()

        #expect(try readLater("nachtigall", context: context) == ["a"])
        #expect(try readLater("saved nachtigall", context: context) == ["a"])
        #expect(try readLater("amsel", context: context).isEmpty)
    }

    @Test("An entry from another device is searched by what its snapshot holds")
    func readLaterFromSync() throws {
        let context = try makeContext()
        context.insert(ReadLaterEntry(
            itemID: "remote",
            sourceID: sourceID,
            accountID: accountID,
            kind: .article,
            title: "From elsewhere",
            sourceTitle: "Feed",
            excerpt: "Only the excerpt came along.",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_700_000_000_000, id: "remote")
        ))
        try context.save()

        #expect(try readLater("excerpt elsewhere", context: context) == ["remote"])
    }

    @Test("An entry saved before the column existed is filled from its cached item")
    func readLaterBackfill() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let item = insert("a", in: context, title: "Saved", html: "<p>Rotkehlchen</p>")
        let entry = try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: false, in: context)
        entry.searchText = nil
        try context.save()

        #expect(try await SearchTextBackfill(modelContainer: container).fillMissing() == 1)
        #expect(try readLater("rotkehlchen", context: ModelContext(container)) == ["a"])
    }
}
