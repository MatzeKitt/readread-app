import Foundation
import SwiftData

/// Adding to and removing from the Read Later list.
///
/// Static functions over a `ModelContext`, matching ``ThresholdService``: these are single-row
/// edits made from the UI in response to a keystroke, so they belong on the main context where the
/// change is visible in the same frame. The batch work — re-evaluating filters, ingest — is what
/// gets an actor.
public enum ReadLaterService {

    /// What a toggle did, so the caller can queue the right sync record.
    public enum Toggle: Sendable, Equatable {
        case saved(itemID: String)
        case removed(itemID: String)
    }

    public static func entry(for itemID: String, in context: ModelContext) throws -> ReadLaterEntry? {
        var descriptor = FetchDescriptor<ReadLaterEntry>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public static func contains(_ itemID: String, in context: ModelContext) throws -> Bool {
        try entry(for: itemID, in: context) != nil
    }

    /// The ids currently saved, for showing the bookmark badge on timeline rows.
    ///
    /// Fetched as a set once per list rather than a `contains` per row: the timeline realises rows
    /// as fast as it can scroll, and a query per cell is the classic way to make a list stutter.
    public static func savedItemIDs(in context: ModelContext) throws -> Set<String> {
        var descriptor = FetchDescriptor<ReadLaterEntry>()
        descriptor.propertiesToFetch = [\.itemID]
        return Set(try context.fetch(descriptor).map(\.itemID))
    }

    /// Saves an item, or updates the snapshot if it is already saved.
    ///
    /// Re-saving deliberately refreshes the snapshot rather than being a no-op: the cached item may
    /// have gained a corrected title or a full body since it was first put aside, and the entry is
    /// the only copy that survives pruning.
    /// - Parameter sourceIconURLString: The feed's favicon, which the *item* does not carry:
    ///   FreshRSS puts `iconUrl` on a subscription, not on an entry, so every saved article
    ///   otherwise had no icon at all. Passed in rather than fetched here for the same reason
    ///   `sourceTitle` is — a snapshot has to stand on its own once the cache is pruned, so it
    ///   cannot point at the feed row and read it later.
    @discardableResult
    public static func save(
        _ item: CachedItem,
        sourceTitle: String,
        sourceIconURLString: String? = nil,
        archiveContent: Bool,
        in context: ModelContext
    ) throws -> ReadLaterEntry {
        if let existing = try entry(for: item.id, in: context) {
            existing.title = item.title
            existing.sourceTitle = sourceTitle
            existing.authorName = item.authorName
            existing.urlString = item.urlString
            existing.excerpt = item.excerpt
            // The item's own first, so a Mastodon post keeps its author's avatar rather than
            // being relabelled with the timeline's icon.
            existing.iconURLString = item.iconURLString ?? sourceIconURLString
            existing.publishedAt = item.publishedAt
            existing.sortKey = item.sortKey
            // `addedAt` is left alone: it is when the user put this aside, and re-snapshotting the
            // body is not a new decision to save it. Overwriting it would reshuffle the list under
            // the reader every time an item was re-ingested.
            if archiveContent { existing.archivedHTML = item.contentHTML }
            return existing
        }

        let entry = ReadLaterEntry(
            snapshotting: item,
            sourceTitle: sourceTitle,
            sourceIconURLString: sourceIconURLString,
            archiveContent: archiveContent
        )
        context.insert(entry)
        return entry
    }

    /// Removes an entry, reporting whether there was one.
    @discardableResult
    public static func remove(itemID: String, in context: ModelContext) throws -> Bool {
        guard let existing = try entry(for: itemID, in: context) else { return false }
        context.delete(existing)
        return true
    }

    /// Saves if absent, removes if present.
    @discardableResult
    public static func toggle(
        _ item: CachedItem,
        sourceTitle: String,
        sourceIconURLString: String? = nil,
        archiveContent: Bool,
        in context: ModelContext
    ) throws -> Toggle {
        if try remove(itemID: item.id, in: context) {
            return .removed(itemID: item.id)
        }
        try save(
            item,
            sourceTitle: sourceTitle,
            sourceIconURLString: sourceIconURLString,
            archiveContent: archiveContent,
            in: context
        )
        return .saved(itemID: item.id)
    }
}
