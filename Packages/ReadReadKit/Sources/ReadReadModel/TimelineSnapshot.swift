import Foundation
import SwiftData

/// One row of a ``TimelineSnapshot``: just enough to place the item and to fetch it again.
public struct TimelineRow: Hashable, Sendable {

    public var id: String
    public var sortKey: SortKey

    /// How a cell gets its `CachedItem` back without a fetch by `id`.
    public var persistentID: PersistentIdentifier

    public init(id: String, sortKey: SortKey, persistentID: PersistentIdentifier) {
        self.id = id
        self.sortKey = sortKey
        self.persistentID = persistentID
    }
}

/// The rows a timeline is showing, frozen.
///
/// ## Why the list does not follow the store
///
/// A live query changes the rows whenever anything is saved: a refresh, a backfill page, retention,
/// a filter re-evaluation. Every one of those can land while the reader has a finger on the list,
/// and a scroll view that has rows inserted or removed under the finger moves the content — which
/// is what "it suddenly jumped" and "it skipped the newer entries" were.
///
/// So the list shows a snapshot, and a newer snapshot replaces it only at a moment the viewport
/// allows — see ``ViewportGate`` — and only through ``AnchorResolver``, so the row under the reader
/// stays where it is. The store is free to change underneath at any time; what is *displayed* is
/// not.
///
/// Sorted newest first, which is the order the whole position design assumes: the rows above the
/// fold are exactly the items newer than it, so the fold's row index is the count.
public struct TimelineSnapshot: Sendable {

    public let rows: [TimelineRow]

    /// Increases with every build, so two snapshots of the same rows can still be told apart.
    public let generation: Int

    private let rowIndex: [String: Int]

    public init(rows: [TimelineRow], generation: Int) {
        self.rows = rows
        self.generation = generation
        var index: [String: Int] = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() where index[row.id] == nil {
            index[row.id] = offset
        }
        rowIndex = index
    }

    public static let empty = TimelineSnapshot(rows: [], generation: 0)

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }

    public func row(of id: String) -> Int? {
        rowIndex[id]
    }

    public func contains(_ id: String) -> Bool {
        rowIndex[id] != nil
    }

    /// Whether the two snapshots show the same rows in the same order.
    public func hasSameRows(as other: TimelineSnapshot) -> Bool {
        rows.count == other.rows.count && rows.map(\.id) == other.rows.map(\.id)
    }

    /// The row a reading position puts at the fold: the item the mark names, or failing that the
    /// newest item older than it.
    ///
    /// Everything newer than the mark sits above this row, so its index is the scope's count — the
    /// same answer `ThresholdService.newerCount` gives from the store, here from the rows actually
    /// on screen.
    ///
    /// - Returns: `nil` for an empty snapshot. A mark older than every item (``SortKey/distantPast``
    ///   included) lands on the last row, and one newer than every item on the first.
    public func foldRow(for mark: SortKey) -> Int? {
        guard !rows.isEmpty else { return nil }

        // Binary search for the first row whose key is not greater than the mark. Rows are sorted
        // descending, so the predicate "key > mark" is true for a prefix and false after it.
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].sortKey > mark {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return min(low, rows.count - 1)
    }
}

/// Builds snapshots off the main actor.
///
/// Fetches two properties per item rather than whole models: a few thousand rows of id and sort
/// key cost a few milliseconds, and nothing in the snapshot needs more. Cells fetch what they draw
/// when they are realised.
@ModelActor
public actor TimelineSnapshotBuilder {

    public func build(scope: ScopeID, generation: Int) throws -> TimelineSnapshot {
        // A context per build, so the models each fetch registers do not pile up in one that
        // lives as long as the list.
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: scope),
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id, \.sortKeyRaw]

        // Deduplicated, because a list keyed by item id cannot hold an id twice — a diffable
        // data source traps on it.
        var seen = Set<String>()
        let rows = try context.fetch(descriptor).compactMap { item -> TimelineRow? in
            guard seen.insert(item.id).inserted else { return nil }
            return TimelineRow(id: item.id, sortKey: item.sortKey, persistentID: item.persistentModelID)
        }
        return TimelineSnapshot(rows: rows, generation: generation)
    }
}
