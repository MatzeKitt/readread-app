import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

@Suite("ReadLaterService")
struct ReadLaterServiceTests {

    private let accountID = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    @discardableResult
    private func insertItem(
        id: String = "feed/1#1",
        title: String = "A fine widget",
        contentHTML: String = "<p>Body</p>",
        in context: ModelContext
    ) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        let item = CachedItem(
            id: id,
            sourceID: "feed/1",
            accountID: accountID,
            kind: .article,
            title: title,
            contentHTML: contentHTML,
            excerpt: "Body",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key
        )
        context.insert(item)
        return item
    }

    @Test("Saving copies everything the entry needs to outlive the cached item")
    func savingSnapshots() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        let entry = try ReadLaterService.save(
            item,
            sourceTitle: "Daring Fireball",
            archiveContent: true,
            in: context
        )
        try context.save()

        // The point of the snapshot: deleting the cache must leave the saved entry intact.
        context.delete(item)
        try context.save()

        #expect(entry.title == "A fine widget")
        #expect(entry.sourceTitle == "Daring Fireball")
        #expect(entry.archivedHTML == "<p>Body</p>")
        #expect(try context.fetchCount(FetchDescriptor<ReadLaterEntry>()) == 1)
    }

    @Test("Archiving off leaves the body out")
    func archivingIsOptional() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        let entry = try ReadLaterService.save(
            item,
            sourceTitle: "Feed",
            archiveContent: false,
            in: context
        )

        #expect(entry.archivedHTML == nil)
    }

    @Test("Re-saving refreshes the snapshot but keeps when it was put aside")
    func resavingKeepsAddedAt() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        let first = try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: true, in: context)
        let addedAt = first.addedAt

        item.title = "A finer widget"
        let second = try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: true, in: context)

        #expect(second.title == "A finer widget")
        // Otherwise a re-ingest would reshuffle the list under the reader, since it is sorted by
        // when things were saved.
        #expect(second.addedAt == addedAt)
        #expect(try context.fetchCount(FetchDescriptor<ReadLaterEntry>()) == 1)
    }

    @Test("Toggling saves and then removes")
    func toggling() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        let saved = try ReadLaterService.toggle(item, sourceTitle: "Feed", archiveContent: false, in: context)
        #expect(saved == .saved(itemID: item.id))
        #expect(try ReadLaterService.contains(item.id, in: context))

        let removed = try ReadLaterService.toggle(item, sourceTitle: "Feed", archiveContent: false, in: context)
        #expect(removed == .removed(itemID: item.id))
        #expect(!(try ReadLaterService.contains(item.id, in: context)))
    }

    @Test("Removing something that was never saved reports that it did nothing")
    func removingAbsentEntry() throws {
        let context = try makeContext()
        #expect(!(try ReadLaterService.remove(itemID: "nope", in: context)))
    }

    @Test("The saved ids come back as a set the timeline can ask per row")
    func savedIDs() throws {
        let context = try makeContext()
        let one = insertItem(id: "feed/1#1", in: context)
        let two = insertItem(id: "feed/1#2", in: context)
        insertItem(id: "feed/1#3", in: context)

        try ReadLaterService.save(one, sourceTitle: "Feed", archiveContent: false, in: context)
        try ReadLaterService.save(two, sourceTitle: "Feed", archiveContent: false, in: context)
        try context.save()

        #expect(try ReadLaterService.savedItemIDs(in: context) == ["feed/1#1", "feed/1#2"])
    }
}

/// The feed's favicon in a saved entry.
///
/// An *item* carries no icon: FreshRSS puts `iconUrl` on a subscription, not on an entry, so
/// `CachedItem.iconURLString` is nil for every article ever ingested. The snapshot has to be handed
/// the feed's, because it exists precisely to keep working once the feed row is gone.
@Suite("Read Later icons")
struct ReadLaterIconTests {

    private let accountID = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func insertItem(
        kind: ItemKind = .article,
        iconURLString: String? = nil,
        in context: ModelContext
    ) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "1")
        let item = CachedItem(
            id: "1",
            sourceID: "feed/1",
            accountID: accountID,
            kind: kind,
            title: "A fine widget",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key,
            iconURLString: iconURLString
        )
        context.insert(item)
        return item
    }

    @Test("An article's entry takes the feed's favicon")
    func articleTakesFeedIcon() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        let entry = try ReadLaterService.save(
            item,
            sourceTitle: "Daring Fireball",
            sourceIconURLString: "https://example.com/f.php?h=abc",
            archiveContent: false,
            in: context
        )

        #expect(entry.iconURLString == "https://example.com/f.php?h=abc")
    }

    /// A post's icon is its *author's* avatar, which is the more specific answer and must not be
    /// overwritten with the timeline's own icon.
    @Test("A post keeps its author's avatar")
    func postKeepsItsOwnIcon() throws {
        let context = try makeContext()
        let item = insertItem(kind: .status, iconURLString: "https://example.com/avatar.png", in: context)

        let entry = try ReadLaterService.save(
            item,
            sourceTitle: "Home",
            sourceIconURLString: "https://example.com/instance.png",
            archiveContent: false,
            in: context
        )

        #expect(entry.iconURLString == "https://example.com/avatar.png")
    }

    /// Re-saving refreshes the snapshot, so it has to refresh this too — a feed that has since
    /// grown a favicon should give it to an entry saved before it had one.
    @Test("Re-saving fills in an icon the entry did not have")
    func resavingFillsIcon() throws {
        let context = try makeContext()
        let item = insertItem(in: context)

        try ReadLaterService.save(item, sourceTitle: "Feed", archiveContent: false, in: context)
        let updated = try ReadLaterService.save(
            item,
            sourceTitle: "Feed",
            sourceIconURLString: "https://example.com/f.php?h=abc",
            archiveContent: false,
            in: context
        )

        #expect(updated.iconURLString == "https://example.com/f.php?h=abc")
        #expect(try context.fetchCount(FetchDescriptor<ReadLaterEntry>()) == 1)
    }
}
