import Foundation
import ReadReadModel
import SwiftData
import Testing

@testable import ReadReadSync

/// A pulled record is not the same as a pulled record having taken effect. Two collections need
/// work afterwards that the apply step cannot do, and neither was being done — the records arrived
/// and changed nothing visible, which from outside is indistinguishable from sync being broken.
@Suite("Pulled side effects")
struct PulledSideEffectTests {

    private let accountID = UUID()

    private func makeStore() throws -> ModelContainer {
        try ReadReadStore.inMemoryContainer()
    }

    private func insertItem(_ id: String, title: String, in context: ModelContext) {
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        context.insert(CachedItem(
            id: id,
            sourceID: "freshrss:acct:feed/1",
            accountID: accountID,
            kind: .article,
            title: title,
            publishedAt: .now,
            sortKey: key,
            ingestKey: key
        ))
    }

    private func filterRecord(pattern: String, id: UUID = UUID()) throws -> SyncRecord {
        SyncRecord(
            collection: .filter,
            id: id.uuidString,
            revision: 1,
            deleted: false,
            updatedAt: 1,
            payload: try SyncPayloadCoding.encodeToString(
                FilterPayload(FilterRule(id: id, pattern: pattern))
            )
        )
    }

    private func page(_ records: [SyncRecord], maxRevision: Int = 1) -> SyncChangesPage {
        SyncChangesPage(records: records, maxRevision: maxRevision, hasMore: false)
    }

    @Test("A pulled filter reports the filter collection as changed")
    func pulledFilterIsReported() async throws {
        let container = try makeStore()
        let store = SyncStore(modelContainer: container)
        let result = try await store.applyReportingCollections(
            page([try filterRecord(pattern: "spoilers")])
        )

        // Without this the caller has no way to know a rule arrived, so nothing re-applies it and
        // the filter hides nothing on this device.
        #expect(result.applied == 1)
        #expect(result.collections == [.filter])
    }

    @Test("Re-applying after the pull is what actually hides the items")
    func reapplyingHidesMatchingItems() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        insertItem("keep", title: "An ordinary article", in: context)
        insertItem("hide", title: "Contains spoilers, sorry", in: context)
        try context.save()

        let store = SyncStore(modelContainer: container)
        _ = try await store.applyReportingCollections(
            page([try filterRecord(pattern: "spoilers")])
        )

        // The rule is here, and by itself it does nothing: `isFilteredOut` is a stored column, and
        // that is what the timeline and every count read.
        let afterApply = ModelContext(container)
        #expect(try afterApply.fetchCount(FetchDescriptor<FilterRule>()) == 1)
        #expect(try afterApply.fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.isFilteredOut })
        ) == 0)

        _ = try await FilterReevaluator(modelContainer: container).reapplyAll()

        let afterReapply = ModelContext(container)
        let hidden = try afterReapply.fetch(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.isFilteredOut })
        )
        #expect(hidden.map(\.id) == ["hide"])
    }

    @Test("A pull that changes nothing reports no collections")
    func unchangedPullReportsNothing() async throws {
        let container = try makeStore()
        let store = SyncStore(modelContainer: container)

        let result = try await store.applyReportingCollections(page([], maxRevision: 7))

        // Re-walking the whole cache on every empty poll would be a filter re-evaluation every
        // thirty seconds, forever.
        #expect(result.applied == 0)
        #expect(result.collections.isEmpty)
    }
}
