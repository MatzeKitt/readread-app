import Foundation
import ReadReadModel
import SwiftData

/// Writing a settled reading position, and queueing the pushes that go with it.
///
/// Its own type because it has two callers that cannot share a context. The debounced write runs on
/// ``PositionWriter``'s background context, off the main actor; the flush at termination has to run
/// on the main one, synchronously, because the process is about to end and an actor hop would not
/// come back. Two copies of a cascade-and-enqueue this fiddly would drift, so the copy lives here
/// and the callers bring the context.
public enum PositionCommit {

    /// Marks `scope` at the item's key, cascading to the scopes it overlaps, and queues the pushes.
    ///
    /// Nothing is saved: the caller decides when, because on the main context the save is shared
    /// with whatever else that turn touched.
    ///
    /// - Returns: `false` when the item is no longer in the store — pruned, filtered out, or its
    ///   account switched off between the fold being read and the debounce elapsing. There is
    ///   nothing to write then, and writing anything else would be a guess.
    @discardableResult
    public static func write(
        scope: ScopeID,
        itemID: String,
        deviceID: String,
        in context: ModelContext
    ) throws -> Bool {
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        guard let item = try context.fetch(descriptor).first else { return false }

        // Cascading, so that scrolling `All Items` carries the folders and feeds inside it instead
        // of leaving their counts to climb forever. See `setPositionCascading`.
        let marks = try ThresholdService.setPositionCascading(
            scope,
            to: item.sortKey,
            deviceID: deviceID,
            in: context
        )
        // Queued in the same transaction as the positions themselves, so one save commits the
        // changes and their pushes together. See `SyncOutbox`.
        for mark in marks {
            try SyncOutbox.record(mark, in: context)
        }
        return true
    }
}

/// Writes settled reading positions on a context of its own.
///
/// ## Why this is not simply done on the main context
///
/// A settled scroll writes more than it looks like. `setPositionCascading` fetches this device's
/// marks, works out every scope the current one contains and every scope that contains it — which
/// means reading the sources — and then writes a row per scope: on a store with forty feeds, forty
/// rows and forty outbox records, followed by a `save()`. All of that used to happen on the main
/// actor, in the middle of reading, and the reader is by definition still holding the scroll
/// gesture when it lands.
///
/// It cannot be moved by wrapping it in a `Task`: a `ModelContext` is not `Sendable` and the main
/// one belongs to the main actor. A context of its own is the only way off, which is what
/// `@ModelActor` provides.
///
/// The item is passed by **id** rather than as a row, for the same reason: a `CachedItem` fetched on
/// the main context cannot cross to this one. Re-fetching here is not waste — it moves that fetch
/// off the main actor as well.
@ModelActor
public actor PositionWriter {

    /// - Returns: Whether a position was written. `false` means the item had left the store, and
    ///   the caller should not record it as written.
    @discardableResult
    public func write(scope: ScopeID, itemID: String, deviceID: String) async -> Bool {
        do {
            guard try PositionCommit.write(
                scope: scope,
                itemID: itemID,
                deviceID: deviceID,
                in: modelContext
            ) else {
                return false
            }
            try modelContext.save()
            return true
        } catch {
            // A position that fails to write is corrected by the next scroll, so there is nothing
            // here worth interrupting the reader for. Reported as not written, so the caller tries
            // again rather than believing the store agrees with the screen.
            return false
        }
    }
}
