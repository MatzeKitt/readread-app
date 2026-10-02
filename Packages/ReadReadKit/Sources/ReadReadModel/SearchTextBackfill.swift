import Foundation
import SwiftData

/// Derives ``CachedItem/searchText`` and ``ReadLaterEntry/searchText`` for rows written before
/// those columns existed.
///
/// Needed for the same reason as `StatusBackfill`: an item already in the store is never fetched
/// again — the walk stops at the first id it knows — so without this, search would find only what
/// arrived after the update, which reads as search not working. Everything needed is already
/// stored, so this is local work with nothing to fail on.
///
/// ## Why this one runs beside the app rather than before it
///
/// The status backfills decode a little JSON per row and finish before the first count is built.
/// This one strips the full HTML body of every article in the store, which for a real cache is
/// seconds of work — and holding the launch for it would trade a search that is briefly
/// incomplete for a window that is briefly unusable. So it runs in the background, newest first,
/// and search is simply more complete a few seconds later.
@ModelActor
public actor SearchTextBackfill {

    /// How many rows to derive before saving.
    ///
    /// Bounded so a first launch does not hold every stripped body in memory at once, and so an
    /// interrupted run keeps what it has already done.
    ///
    /// Larger than `StatusBackfill`'s, and the cost it is weighed against is on the main thread,
    /// not here. This runs while the window is open, and every save wakes the timeline's `@Query`
    /// and the sidebar's counts — a quarter of a second of re-fetch each, for a store of a few
    /// thousand items. At a hundred rows a batch that was fifty re-fetches through the first launch;
    /// at five hundred it is ten, for a few megabytes of text held at once.
    private static let batchSize = 500

    /// Fills in every row still missing its search text.
    ///
    /// - Returns: How many rows were updated. Zero on every launch after the first, because the
    ///   predicates match nothing once the work is done — which is what makes this safe to call
    ///   unconditionally at startup instead of tracking a migration flag.
    @discardableResult
    public func fillMissing() throws -> Int {
        try fillMissingItems() + fillMissingReadLaterEntries()
    }

    func fillMissingItems() throws -> Int {
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.searchText == nil },
            // Newest first, so that what a reader is likeliest to go looking for — the last few
            // days — is searchable soonest.
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            try Task.checkCancellation()

            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            // Always non-nil once written, so every row fetched leaves the predicate and the loop
            // cannot spin on one it failed to answer.
            for row in rows {
                row.searchText = SearchText.make(for: row)
            }
            updated += rows.count
            try modelContext.save()
        }

        return updated
    }

    func fillMissingReadLaterEntries() throws -> Int {
        let entries = try modelContext.fetch(
            FetchDescriptor<ReadLaterEntry>(predicate: #Predicate { $0.searchText == nil })
        )
        guard !entries.isEmpty else { return 0 }

        for entry in entries {
            // The cached item's text when it is still here, which covers the whole body; an entry
            // saved without archiving holds only its excerpt. `ItemResolution` is not needed: this
            // is about the entry's own item, and one that is gone falls back to the snapshot.
            let itemID = entry.itemID
            var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == itemID })
            descriptor.fetchLimit = 1

            if let item = try modelContext.fetch(descriptor).first {
                entry.searchText = item.searchText ?? SearchText.make(for: item)
            } else {
                entry.searchText = ReadLaterEntry.searchText(
                    title: entry.title,
                    authorName: entry.authorName,
                    excerpt: entry.excerpt,
                    archivedHTML: entry.archivedHTML
                )
            }
        }

        try modelContext.save()
        return entries.count
    }
}
