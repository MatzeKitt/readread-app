import Foundation
import SwiftData

/// Finds the item before or after another one, in a scope's own order.
///
/// Kept in the model layer and driven by ``ScopeQuery``, so "the next item" means the same thing
/// to a swipe on iPhone as it does to the down arrow on a Mac. Two definitions of adjacency would
/// diverge the first time an exclusion was added to one of them.
public enum TimelineNavigator {

    public enum Direction: Sendable {
        /// Towards the top of the list: more recently published.
        case newer
        /// Towards the bottom.
        case older
    }

    /// The id of the neighbouring item, or `nil` at either end of the list.
    ///
    /// One row is fetched, not the scope's whole timeline: this runs on a swipe, and the answer is
    /// always the single nearest item in the direction of travel.
    public static func adjacentItemID(
        to itemID: String,
        in scope: ScopeID,
        direction: Direction,
        context: ModelContext
    ) throws -> String? {
        guard let current = try item(itemID, in: context) else { return nil }
        guard let predicate = ScopeQuery.adjacentPredicate(
            for: scope,
            bound: current.sortKeyRaw,
            isNewer: direction == .newer
        ) else { return nil }

        // Sorted *towards* the neighbour, so the first row past the bound is the answer.
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortKeyRaw, order: direction == .newer ? .forward : .reverse)]
        )
        // No `propertiesToFetch`: with a limit of one row there is nothing to save, and asking for
        // a subset that omits what the predicate and sort read crashes the fetch outright.
        descriptor.fetchLimit = 1

        return try context.fetch(descriptor).first?.id
    }

    private static func item(_ id: String, in context: ModelContext) throws -> CachedItem? {
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
