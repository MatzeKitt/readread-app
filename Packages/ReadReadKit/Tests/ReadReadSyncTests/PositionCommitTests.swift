import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadSync

/// The one write a settled scroll performs, and the two callers that have to agree about it.
///
/// Split out of the timeline so the debounced write can run off the main actor — see
/// ``PositionWriter`` — which left the same logic reachable from two contexts. These tests pin what
/// both of them do: mark the scope, cascade to the scopes it overlaps, and queue every row it
/// touched for sync in the same transaction. Missing the outbox half is the failure that looks like
/// nothing at all locally and like a device that never syncs from the other end.
@Suite("Position commit")
struct PositionCommitTests {

    private let accountID = UUID()
    private let device = "device-a"

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func insertSource(id: String, folder: String?, in context: ModelContext) {
        context.insert(CachedSource(
            id: id,
            accountID: accountID,
            kind: .article,
            title: id,
            folderName: folder
        ))
    }

    @discardableResult
    private func insertItem(id: String, sourceID: String, millis: Int64, in context: ModelContext) -> CachedItem {
        let key = SortKey(millis: millis, id: id)
        let item = CachedItem(
            id: id,
            sourceID: sourceID,
            accountID: accountID,
            kind: .article,
            title: id,
            publishedAt: Date(millisecondsSinceEpoch: millis),
            sortKey: key,
            ingestKey: key
        )
        context.insert(item)
        return item
    }

    private func marks(in context: ModelContext) throws -> [String: SortKey] {
        let rows = try context.fetch(FetchDescriptor<PositionMark>())
        return Dictionary(rows.map { ($0.scopeRaw, $0.markSortKey) }, uniquingKeysWith: { first, _ in first })
    }

    private func queued(in context: ModelContext) throws -> [PendingChange] {
        try context.fetch(FetchDescriptor<PendingChange>())
    }

    // MARK: - Writing

    @Test("A commit marks the scope at the item's key and queues it")
    func marksAndQueues() throws {
        let context = try makeContext()
        insertSource(id: "feed/1", folder: "RSS", in: context)
        let item = insertItem(id: "feed/1#5", sourceID: "feed/1", millis: 1_700_000_005_000, in: context)

        let wrote = try PositionCommit.write(
            scope: .source("feed/1"),
            itemID: item.id,
            deviceID: device,
            in: context
        )

        #expect(wrote)
        #expect(try marks(in: context)[ScopeID.source("feed/1").rawValue] == item.sortKey)
        #expect(try !queued(in: context).isEmpty)
    }

    /// The cascade is the reason this is not a one-line write, and the reason it is worth having
    /// off the main actor: one settled scroll of `All Items` touches every folder and feed inside
    /// it, and each row is a sync record too.
    @Test("A commit carries the scopes the one being scrolled contains")
    func cascadesInwards() throws {
        let context = try makeContext()
        insertSource(id: "feed/1", folder: "RSS", in: context)
        insertSource(id: "feed/2", folder: "RSS", in: context)
        let item = insertItem(id: "feed/1#5", sourceID: "feed/1", millis: 1_700_000_005_000, in: context)
        insertItem(id: "feed/2#5", sourceID: "feed/2", millis: 1_700_000_004_000, in: context)

        try PositionCommit.write(scope: .all, itemID: item.id, deviceID: device, in: context)

        let written = try marks(in: context)
        #expect(written[ScopeID.all.rawValue] == item.sortKey)
        #expect(written[ScopeID.folder("RSS").rawValue] == item.sortKey)
        #expect(written[ScopeID.source("feed/1").rawValue] == item.sortKey)
        #expect(written[ScopeID.source("feed/2").rawValue] == item.sortKey)

        // One record per row written, so the other device learns about all of them rather than
        // about the scope that happened to be on screen.
        #expect(try queued(in: context).count == written.count)
    }

    /// The case that makes the return value load-bearing. The fold is read from the screen and
    /// written a second and a half later, and in between an ingest can prune the row, a filter can
    /// hide it, or its account can be switched off. Writing *something* then would be a guess at a
    /// position that has no backup — this app has no read/unread state to reconstruct one from.
    @Test("A commit for an item that has left the store writes nothing")
    func missingItemWritesNothing() throws {
        let context = try makeContext()
        insertSource(id: "feed/1", folder: "RSS", in: context)

        let wrote = try PositionCommit.write(
            scope: .source("feed/1"),
            itemID: "feed/1#gone",
            deviceID: device,
            in: context
        )

        #expect(wrote == false)
        #expect(try marks(in: context).isEmpty)
        #expect(try queued(in: context).isEmpty)
    }

    // MARK: - Off the main actor

    /// The background writer is the debounced path, and what has to be true of it is that it lands
    /// in the *store* — the main context reads positions back from there, and the counts recompute
    /// on `ModelContext.didSave`. A write that stayed in an unsaved background context would look
    /// exactly like the position never being written.
    @Test("The background writer saves what it wrote")
    func backgroundWriterSaves() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        insertSource(id: "feed/1", folder: "RSS", in: context)
        let item = insertItem(id: "feed/1#5", sourceID: "feed/1", millis: 1_700_000_005_000, in: context)
        try context.save()

        let writer = PositionWriter(modelContainer: container)
        let wrote = await writer.write(scope: .source("feed/1"), itemID: item.id, deviceID: device)

        #expect(wrote)
        // Read through a *third* context, so this cannot pass on the writer's own unsaved state.
        let reader = ModelContext(container)
        #expect(try marks(in: reader)[ScopeID.source("feed/1").rawValue] == item.sortKey)
    }

    @Test("The background writer reports an item that is no longer there")
    func backgroundWriterReportsMissing() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let writer = PositionWriter(modelContainer: container)

        #expect(await writer.write(scope: .all, itemID: "feed/1#gone", deviceID: device) == false)
    }
}
