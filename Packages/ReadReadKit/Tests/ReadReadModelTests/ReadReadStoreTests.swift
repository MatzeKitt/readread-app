import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// SwiftData validates a schema when the container is built, not when it compiles, so a broken
/// `#Unique`, `#Index` or attribute type only surfaces at runtime. These tests exist so that
/// surfaces here rather than on launch.
@Suite("ReadReadStore")
struct ReadReadStoreTests {

    @Test("The schema builds a container")
    func schemaBuildsContainer() throws {
        let container = try ReadReadStore.inMemoryContainer()

        #expect(container.schema.entities.count == ReadReadStore.schema.entities.count)
    }

    @Test("Every model can be inserted and read back")
    func everyModelRoundTrips() throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let accountID = UUID()

        context.insert(AccountRecord(
            kind: .freshRSS,
            displayName: "Home",
            serverURLString: "https://rss.example.net",
            username: "matze"
        ))
        context.insert(CachedSource(
            id: "freshrss:\(accountID):feed/1",
            accountID: accountID,
            kind: .article,
            title: "Example Feed"
        ))
        context.insert(CachedItem(
            id: "freshrss:\(accountID):deadbeef",
            sourceID: "freshrss:\(accountID):feed/1",
            accountID: accountID,
            kind: .article,
            title: "An article",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_700_000_000_000, id: "deadbeef"),
            ingestKey: SortKey(millis: 1_700_000_100_000, id: "deadbeef")
        ))
        context.insert(SyncCursor(accountID: accountID, streamKey: "reading-list"))
        context.insert(PositionMark(scope: .all, deviceID: "device-a"))
        context.insert(FilterRule(pattern: "sponsored"))
        context.insert(PendingChange(collection: .position, recordID: "all|device-a", payload: Data("{}".utf8)))
        context.insert(ReadLaterEntry(
            itemID: "freshrss:\(accountID):deadbeef",
            sourceID: "freshrss:\(accountID):feed/1",
            accountID: accountID,
            kind: .article,
            title: "An article",
            sourceTitle: "Example Feed",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_700_000_000_000, id: "deadbeef")
        ))

        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<AccountRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedSource>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SyncCursor>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PositionMark>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<FilterRule>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PendingChange>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ReadLaterEntry>()) == 1)
    }

    /// `#Unique` is what stops a re-ingested page from duplicating items. SwiftData upserts on a
    /// unique collision rather than throwing, which is exactly the behaviour ingest relies on.
    @Test("Re-inserting an item with the same id upserts instead of duplicating")
    func uniqueIDUpserts() throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let accountID = UUID()

        for title in ["First title", "Corrected title"] {
            context.insert(CachedItem(
                id: "freshrss:x:deadbeef",
                sourceID: "freshrss:x:feed/1",
                accountID: accountID,
                kind: .article,
                title: title,
                publishedAt: .now,
                sortKey: SortKey(millis: 1_700_000_000_000, id: "deadbeef"),
                ingestKey: SortKey(millis: 1_700_000_000_000, id: "deadbeef")
            ))
            try context.save()
        }

        let items = try context.fetch(FetchDescriptor<CachedItem>())
        #expect(items.count == 1)
        #expect(items.first?.title == "Corrected title")
    }

    /// The predicate form the entire threshold design depends on. If `sortKeyRaw > mark` is not
    /// expressible against the store, sidebar counts cannot be a `fetchCount`.
    @Test("Counting items newer than a marker works as a store-side predicate")
    func newerThanMarkerCountsInStore() throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let accountID = UUID()
        let sourceID = "freshrss:x:feed/1"

        // Ten items, one per second.
        for offset in 0..<10 {
            let millis = Int64(1_700_000_000_000 + offset * 1_000)
            context.insert(CachedItem(
                id: "item-\(offset)",
                sourceID: sourceID,
                accountID: accountID,
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: SortKey(millis: millis, id: "item-\(offset)"),
                ingestKey: SortKey(millis: millis, id: "item-\(offset)")
            ))
        }
        // A filtered item above the marker must not be counted.
        context.insert(CachedItem(
            id: "item-filtered",
            sourceID: sourceID,
            accountID: accountID,
            kind: .article,
            title: "Sponsored",
            publishedAt: .now,
            sortKey: SortKey(millis: 1_700_000_020_000, id: "item-filtered"),
            ingestKey: SortKey(millis: 1_700_000_020_000, id: "item-filtered"),
            isFilteredOut: true
        )
        )
        try context.save()

        // Marker at item 6, so items 7, 8 and 9 are newer.
        let mark = SortKey(millis: 1_700_000_006_000, id: "item-6").rawValue
        let descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.sortKeyRaw > mark && !$0.isFilteredOut }
        )

        #expect(try context.fetchCount(descriptor) == 3)
    }

    @Test("An unread scope counts every item")
    func distantPastMarkerCountsEverything() throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)

        for offset in 0..<5 {
            let millis = Int64(1_700_000_000_000 + offset * 1_000)
            context.insert(CachedItem(
                id: "item-\(offset)",
                sourceID: "s",
                accountID: UUID(),
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: SortKey(millis: millis, id: "item-\(offset)"),
                ingestKey: SortKey(millis: millis, id: "item-\(offset)")
            ))
        }
        try context.save()

        let mark = SortKey.distantPast.rawValue
        let descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.sortKeyRaw > mark })

        #expect(try context.fetchCount(descriptor) == 5)
    }
}

@Suite("AccountRecord")
struct AccountRecordTests {

    @Test("A server address without a host is not usable")
    func serverURLRequiresHost() {
        let account = AccountRecord(
            kind: .freshRSS,
            displayName: "Broken",
            serverURLString: "not a url",
            username: "matze"
        )

        // `URL(string:)` percent-encodes this into a relative URL rather than refusing it, so a
        // plain nil check let a typo through as far as an outgoing request.
        #expect(account.serverURL == nil)
    }

    @Test("A well-formed address survives")
    func serverURLKeepsGoodAddresses() {
        let account = AccountRecord(
            kind: .freshRSS,
            displayName: "Home",
            serverURLString: "https://rss.example.com",
            username: "matze"
        )

        #expect(account.serverURL?.host() == "rss.example.com")
    }
}
