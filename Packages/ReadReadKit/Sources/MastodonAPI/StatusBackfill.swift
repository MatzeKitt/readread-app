import Foundation
import ReadReadModel
import SwiftData

/// Fills in status columns on rows that were written before those columns existed.
///
/// Needed because of how the timeline walk works, not because of a mistake in it. Ingest pages
/// newest-first and stops at the first id it already has, which is what makes an incremental
/// refresh one request instead of a full re-download — but it also means a post that is already
/// in the store is **never visited again**. Adding a column therefore leaves every existing row
/// with its default value forever, and no amount of refreshing fixes it. The handle under a
/// display name would have appeared only on posts published after the update, which reads as the
/// feature simply not working.
///
/// Recovered from ``CachedItem/mastodonPayload`` rather than from the network: the whole status
/// is already stored for the detail view, so this is a local decode with no server involved and
/// nothing to fail on. That is also the standing answer for any future column derived from a
/// status — add it here rather than hoping a refresh will backfill it.
@ModelActor
public actor StatusBackfill {

    /// How many rows to decode before saving.
    ///
    /// Bounded so a first launch against a large timeline does not hold every decoded status in
    /// memory at once, and so an interrupted run keeps the work it has already done.
    private static let batchSize = 200

    /// Fills in `authorHandle` for statuses that have a payload but no handle.
    ///
    /// - Returns: How many rows were updated. Zero on every launch after the first, because the
    ///   predicate matches nothing once the work is done — which is what makes this safe to call
    ///   unconditionally at startup instead of tracking a migration flag.
    @discardableResult
    public func fillMissingAuthorHandles() throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind && $0.authorHandle == nil && $0.mastodonPayload != nil
            }
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            var changed = 0
            for row in rows {
                guard
                    let payload = row.mastodonPayload,
                    let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
                else {
                    // A payload that will not decode cannot be recovered from, and leaving it
                    // matching the predicate would spin this loop forever. An empty string is not
                    // nil, so the row drops out of the search while still rendering as no handle.
                    row.authorHandle = ""
                    continue
                }
                row.authorHandle = status.displayStatus.account.acct
                changed += 1
            }

            try modelContext.save()
            updated += changed

            // Every row fetched was rewritten to something non-nil, so the next fetch returns the
            // next batch rather than the same one. A short page means the store is exhausted.
            if rows.count < Self.batchSize { break }
        }

        return updated
    }

    /// Fills in `isSensitive` and attachment preview URLs for statuses that predate them.
    ///
    /// Both are needed before the timeline can show media inline, and they are filled together
    /// because they come out of the same decode. The sensitive flag is the load-bearing one: the
    /// timeline treats an unanswered `isSensitive` as sensitive, so until this runs a status with
    /// media simply shows no thumbnail rather than showing one it should have blurred.
    ///
    /// - Returns: How many rows were updated.
    @discardableResult
    public func fillMissingMediaMetadata() throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind && $0.isSensitive == nil && $0.mastodonPayload != nil
            }
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            var changed = 0
            for row in rows {
                guard
                    let payload = row.mastodonPayload,
                    let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
                else {
                    // Undecodable, and it has to leave the predicate or this loop never ends.
                    // `true` rather than `false`, because the one thing worse than a missing
                    // thumbnail is an unblurred one that should have been hidden.
                    row.isSensitive = true
                    continue
                }

                let display = status.displayStatus
                row.isSensitive = display.sensitive

                // Re-derived rather than patched into the existing array: the attachment list is a
                // property of the server's copy, and this is that copy.
                let rebuilt = display.mediaAttachments.compactMap(MastodonIngestPlanner.attachment(from:))
                if !rebuilt.isEmpty {
                    row.attachments = rebuilt
                }
                changed += 1
            }

            try modelContext.save()
            updated += changed

            if rows.count < Self.batchSize { break }
        }

        return updated
    }

    /// Fills in `boostedByName` for statuses that predate the column.
    ///
    /// Without this the list would name the booster only on posts that arrived after the update,
    /// which for a timeline refreshed every five minutes means the feature appears to work on the
    /// top few rows and be broken everywhere below them.
    ///
    /// - Returns: How many rows were found to be boosts. Rows that turn out not to be boosts are
    ///   still written — see the empty string below — so this number is smaller than the number of
    ///   rows visited, and it is not a measure of work done.
    @discardableResult
    public func fillMissingBoostAttribution() throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind && $0.boostedByName == nil && $0.mastodonPayload != nil
            }
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            var changed = 0
            for row in rows {
                guard
                    let payload = row.mastodonPayload,
                    let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
                else {
                    // Undecodable, and it has to leave the predicate or this loop never ends.
                    row.boostedByName = ""
                    continue
                }

                // The empty string is doing real work here. Most posts are not boosts, so leaving
                // them nil would leave them matching the predicate — the same batch would be
                // fetched, decoded and discarded on every pass, for ever. "" reads as no boost
                // and is an answer.
                let booster = status.boostedBy?.bestDisplayName
                row.boostedByName = booster ?? ""
                if booster != nil { changed += 1 }
            }

            try modelContext.save()
            updated += changed

            if rows.count < Self.batchSize { break }
        }

        return updated
    }

    /// Fills in the link preview columns for statuses that predate them.
    ///
    /// Worth having rather than waiting for the next refresh, for the reason at the top of this
    /// file: the walk stops at the first id it already knows, so a post already in the store is
    /// never visited again. Without this the cards would appear only under posts published after
    /// the update — a handful at the top of the timeline and nothing below them, which reads as a
    /// feature that half works.
    ///
    /// - Returns: How many rows turned out to have a card. Rows that turn out to have none are
    ///   still written — see the sentinel below — so this is smaller than the number of rows
    ///   visited and is not a measure of work done.
    @discardableResult
    public func fillMissingLinkCards() throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind && $0.cardURLString == nil && $0.mastodonPayload != nil
            }
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            var changed = 0
            for row in rows {
                guard
                    let payload = row.mastodonPayload,
                    let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
                else {
                    // Undecodable, and it has to leave the predicate or this loop never ends.
                    row.linkCard = nil
                    continue
                }

                // Assigned even when there is no card. The setter writes the empty-string
                // sentinel, which is what makes this row stop matching the predicate — most posts
                // link to nothing, so leaving those nil would re-fetch and re-decode the same
                // batch on every launch for ever.
                let card = MastodonIngestPlanner.linkCard(from: status.displayStatus.card)
                row.linkCard = card
                if card != nil { changed += 1 }
            }

            try modelContext.save()
            updated += changed

            if rows.count < Self.batchSize { break }
        }

        return updated
    }

    /// Fills in `isFavourited` and `isReblogged` for statuses that predate them.
    ///
    /// The flags decide whether the timeline offers Like or Unlike, so without this every post
    /// already in the store would offer Like — including ones the reader had favourited from
    /// another client. Harmless at the server (favouriting twice is a no-op) and wrong on screen,
    /// which is the kind of wrong that makes a feature look untrustworthy.
    ///
    /// Recovered from the stored payload, which is sound because that payload was fetched with the
    /// account's own token: the flags in it are that account's answer, taken at fetch time. Stale
    /// by exactly as much as the counts beside them.
    ///
    /// - Returns: How many rows were updated.
    @discardableResult
    public func fillMissingInteractionState() throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind && $0.isFavourited == nil && $0.mastodonPayload != nil
            }
        )
        descriptor.fetchLimit = Self.batchSize

        var updated = 0

        while true {
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { break }

            var changed = 0
            for row in rows {
                guard
                    let payload = row.mastodonPayload,
                    let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
                else {
                    // Undecodable, and it has to leave the predicate or this loop never ends.
                    // `false` is the safe answer: it offers Like on a post that may already be
                    // liked, which the server absorbs, where `true` would offer Unlike on one that
                    // is not and quietly do nothing.
                    row.isFavourited = false
                    row.isReblogged = false
                    continue
                }

                let display = status.displayStatus
                // Defaulted rather than carried as nil, for the same reason the empty string is
                // used elsewhere here: nil keeps the row matching the predicate, and a payload
                // fetched before Mastodon sent these fields would be re-decoded on every launch.
                row.isFavourited = display.favourited ?? false
                row.isReblogged = display.reblogged ?? false
                changed += 1
            }

            try modelContext.save()
            updated += changed

            if rows.count < Self.batchSize { break }
        }

        return updated
    }
}
