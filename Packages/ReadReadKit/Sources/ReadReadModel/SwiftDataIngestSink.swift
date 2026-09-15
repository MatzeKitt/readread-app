import Foundation
import SwiftData

/// Writes ingest results into the SwiftData store.
///
/// A `@ModelActor`, so it owns a background `ModelContext` and ingest never touches the main
/// context. That matters because a page is up to a hundred items with HTML bodies, and doing that
/// work on the main actor would drop frames while the user is scrolling.
@ModelActor
public actor SwiftDataIngestSink: IngestSink {

    /// Decides whether an item should be hidden by the user's filter rules.
    ///
    /// A closure over a ``FilterSubject`` rather than a direct ``FilterEngine`` dependency:
    /// filtering is evaluated at ingest, but which rules exist and when they were last recompiled
    /// belongs to the app, and ingest should not have to know. Nil means nothing is filtered.
    public typealias FilterEvaluator = @Sendable (FilterSubject) -> Bool

    private var shouldHide: FilterEvaluator?

    /// Source titles resolved during this run, so a rule that matches on the source name does not
    /// cost a fetch per item. Cleared whenever sources are written, since a title can change.
    private var sourceTitles: [String: String] = [:]

    /// This device's id, used when seeding a new scope's reading position.
    private var deviceID: String = ""

    /// Whether ingest may seed a position for a scope that has none.
    ///
    /// Must be `false` until this device knows its real reading positions. Seeding writes a row
    /// dated now, and reduction takes the most recently written row — so a second device that
    /// ingested before its first sync pull landed would seed itself to the top and outrank the
    /// position it was about to receive. The app therefore leaves this off while a sync account
    /// exists that has never completed a pull.
    ///
    /// Defaults to `true` for the single-device case, where there is nothing to wait for.
    private var maySeedMarkers = true

    public func configure(
        deviceID: String,
        maySeedMarkers: Bool = true,
        shouldHide: FilterEvaluator? = nil
    ) {
        self.deviceID = deviceID
        self.maySeedMarkers = maySeedMarkers
        self.shouldHide = shouldHide
    }

    // MARK: - Cursors

    public func cursorState(accountID: UUID, streamKey: String) throws -> IngestCursorState {
        guard let cursor = try fetchCursor(accountID: accountID, streamKey: streamKey) else {
            return .fresh
        }
        return IngestCursorState(
            highestSeenID: cursor.highestSeenID,
            resumeContinuation: cursor.resumeContinuation,
            isWalkInProgress: cursor.isWalkInProgress,
            pendingHighestSeenID: cursor.pendingHighestSeenID,
            historyWindowDays: cursor.historyWindowDays
        )
    }

    private func fetchCursor(accountID: UUID, streamKey: String) throws -> SyncCursor? {
        let key = SyncCursor.key(accountID: accountID, streamKey: streamKey)
        var descriptor = FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func cursor(accountID: UUID, streamKey: String) throws -> SyncCursor {
        if let existing = try fetchCursor(accountID: accountID, streamKey: streamKey) {
            return existing
        }
        let created = SyncCursor(accountID: accountID, streamKey: streamKey)
        modelContext.insert(created)
        return created
    }

    // MARK: - Committing a page

    /// Writes a page's items and its resume cursor in one `save()`.
    ///
    /// The single save is the whole point. Items without the cursor would be re-fetched and
    /// re-inserted after a crash; the cursor without the items would skip them permanently.
    @discardableResult
    public func commit(
        items: [IngestedItem],
        accountID: UUID,
        streamKey: String,
        resumeContinuation: String,
        pendingHighestSeenID: String
    ) throws -> Int {
        var lateArrivals = 0

        // Nothing is a "late arrival" until one full walk has finished.
        //
        // A late arrival means an item that turned up *after* you had read past where it belongs.
        // During the first backfill nothing has been read past — the marker was seeded at the
        // newest item precisely so the backlog would sit quietly below it — and the walk then pages
        // *downwards* through that backlog. Every page after the first therefore arrived below the
        // marker and was flagged, which turned "3 older items arrived" into the entire history of
        // every feed: measured against a real account, 5,611 of them.
        //
        // `highestSeenID` is empty until a run completes, which is exactly the condition wanted —
        // it is the same flag that tells the walk it has no stop line yet.
        let isFirstWalk = try cursor(accountID: accountID, streamKey: streamKey).highestSeenID.isEmpty

        if !items.isEmpty {
            // Markers are looked up once per page rather than once per item: the global marker is
            // one query and each distinct source is one more, so a hundred-item page costs a
            // handful of fetches instead of two hundred.
            let globalMark = try ThresholdService.effectivePosition(for: .all, in: modelContext).markSortKey
            var sourceMarks: [String: SortKey] = [:]

            for item in items {
                let sourceMark: SortKey
                if let cached = sourceMarks[item.sourceID] {
                    sourceMark = cached
                } else {
                    sourceMark = try ThresholdService
                        .effectivePosition(for: .source(item.sourceID), in: modelContext)
                        .markSortKey
                    sourceMarks[item.sourceID] = sourceMark
                }

                // "Late" means the item landed below a marker the user actually reads behind, so
                // chronological ordering hides it where it would otherwise read as already-seen.
                let threshold = max(globalMark, sourceMark)
                let arrivedLate = !isFirstWalk && item.sortKey <= threshold
                if arrivedLate { lateArrivals += 1 }

                upsert(item, arrivedLate: arrivedLate)
            }
        }

        let cursor = try cursor(accountID: accountID, streamKey: streamKey)
        cursor.resumeContinuation = resumeContinuation
        cursor.pendingHighestSeenID = pendingHighestSeenID
        cursor.isWalkInProgress = true

        try modelContext.save()
        return lateArrivals
    }

    /// Inserts or updates one item.
    ///
    /// An explicit fetch-then-update rather than relying on the `#Unique` upsert, because a
    /// re-ingested item must keep the flags the *app* owns — `arrivedLate` in particular, which is
    /// a judgement made when the item first appeared and would be wrong to recompute against a
    /// marker that has since moved past it.
    private func upsert(_ item: IngestedItem, arrivedLate: Bool) {
        let id = item.id
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1

        let hidden = shouldHide.map { $0(FilterSubject(item, sourceTitle: sourceTitle(for: item.sourceID))) } ?? false

        if let existing = try? modelContext.fetch(descriptor).first {
            // Content can legitimately change — a corrected article, an edited post — so the body
            // is refreshed, but the arrival judgement is left alone.
            existing.title = item.title
            existing.authorName = item.authorName
            existing.authorHandle = item.authorHandle
            existing.urlString = item.urlString
            existing.contentHTML = item.contentHTML
            existing.excerpt = item.excerpt
            existing.publishedAt = item.publishedAt
            existing.sortKey = item.sortKey
            existing.folderName = item.folderName
            existing.iconURLString = item.iconURLString ?? existing.iconURLString
            existing.attachments = item.attachments
            existing.isSensitive = item.isSensitive ?? existing.isSensitive
            existing.mastodonPayload = item.mastodonPayload ?? existing.mastodonPayload
            existing.isFilteredOut = hidden
            // Refreshed on every re-ingest, unlike `arrivedLate`: these are a live property of the
            // post on the server, and a boost count frozen at first sight would be worse than not
            // showing one at all.
            if let engagement = item.engagement {
                existing.replyCount = engagement.replyCount
                existing.reblogCount = engagement.reblogCount
                existing.favouriteCount = engagement.favouriteCount
                existing.inReplyToStatusID = engagement.inReplyToStatusID
                // Written even when nil, unlike the icon and the payload above: nil here is a
                // fact — this arrival was not a boost — and carrying the previous value forward
                // would leave a post that someone once boosted attributed to them for ever.
                // Empty rather than nil, so it also counts as *answered* for the backfill.
                existing.boostedByName = engagement.boostedByName ?? ""
                // Carried forward when the server did not say, unlike the counts above. A missing
                // answer is not the same as "no longer favourited", and overwriting a known `true`
                // with nil would make a liked post offer Like again after a refresh.
                existing.isFavourited = engagement.isFavourited ?? existing.isFavourited
                existing.isReblogged = engagement.isReblogged ?? existing.isReblogged
            }
            // Assigned for every status, including when there is no card, because the setter
            // writes the empty-string sentinel for nil — which is what records the row as
            // *examined* and keeps it out of the backfill's search. A card is also a live property
            // of the post: an instance often resolves one minutes after the post arrived, so a
            // re-ingest is where a card first appears.
            if item.kind == .status {
                existing.linkCard = item.linkCard
            }
            return
        }

        modelContext.insert(CachedItem(
            id: item.id,
            sourceID: item.sourceID,
            accountID: item.accountID,
            folderName: item.folderName,
            kind: item.kind,
            title: item.title,
            authorName: item.authorName,
            authorHandle: item.authorHandle,
            urlString: item.urlString,
            contentHTML: item.contentHTML,
            excerpt: item.excerpt,
            publishedAt: item.publishedAt,
            sortKey: item.sortKey,
            ingestKey: item.ingestKey,
            arrivedLate: arrivedLate,
            isSensitive: item.isSensitive,
            iconURLString: item.iconURLString,
            isFilteredOut: hidden,
            replyCount: item.engagement?.replyCount ?? 0,
            reblogCount: item.engagement?.reblogCount ?? 0,
            favouriteCount: item.engagement?.favouriteCount ?? 0,
            boostedByName: item.engagement.map { $0.boostedByName ?? "" },
            isFavourited: item.engagement?.isFavourited,
            isReblogged: item.engagement?.isReblogged,
            // Kept even when nil, which for a status records *examined, no card*. The
            // initialiser is what limits that to statuses.
            linkCard: item.linkCard,
            inReplyToStatusID: item.engagement?.inReplyToStatusID,
            attachments: item.attachments,
            mastodonPayload: item.mastodonPayload
        ))
    }

    /// The title of a source, memoised for the duration of the run.
    ///
    /// Only consulted when a rule actually inspects the source name, because the closure is what
    /// builds the subject — but the memo is worth having unconditionally: without it a single
    /// source-name rule would turn every ingested item into a fetch.
    private func sourceTitle(for sourceID: String) -> String? {
        if let cached = sourceTitles[sourceID] { return cached }

        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        guard let title = try? modelContext.fetch(descriptor).first?.title else { return nil }

        sourceTitles[sourceID] = title
        return title
    }

    // MARK: - Run completion

    public func completeRun(
        accountID: UUID,
        streamKey: String,
        highestSeenID: String,
        historyWindowDays: Int = 0
    ) throws {
        let cursor = try cursor(accountID: accountID, streamKey: streamKey)
        cursor.highestSeenID = highestSeenID
        cursor.historyWindowDays = historyWindowDays
        cursor.resumeContinuation = ""
        cursor.pendingHighestSeenID = ""
        cursor.isWalkInProgress = false
        cursor.lastCompletedRunAt = .now

        try seedUnmarkedScopes()
        try modelContext.save()
    }

    public func abandonRun(accountID: UUID, streamKey: String) throws {
        // Deliberately does *not* touch `highestSeenID` or the resume cursor: the whole point of
        // the two-cursor scheme is that an unfinished run leaves the stop line where it was.
        try modelContext.save()
    }

    /// Places a marker at the newest item for every scope that has none.
    ///
    /// Without this, subscribing to a feed dumps its entire backlog above the threshold and the
    /// badge jumps by hundreds — which reads as a bug, and buries whatever the user was actually
    /// reading.
    ///
    /// The rule is deliberately "unmarked scopes" rather than "sources created during this run".
    /// Aggregate scopes — `All Items` and each folder — carry their own markers and nothing else
    /// creates them, so tracking only new *sources* left them behind: on a first sync every feed
    /// correctly showed zero while `All Items` showed the entire backlog, the sidebar visibly
    /// contradicting itself, and a feed moved into a new folder flooded that folder's count while
    /// still reading zero itself. Seeding whatever is unmarked treats all of those the same way.
    ///
    /// Only ever seeds a scope with *no* position. Moving one that already has a position would be
    /// far worse than leaving it alone: adding a single feed would drag `All Items` up to that
    /// feed's newest item, discarding where the user actually was.
    private func seedUnmarkedScopes() throws {
        guard maySeedMarkers, !deviceID.isEmpty else { return }

        // Folders are implied by their sources; a folder with no subscribed source has no items to
        // seed a marker from anyway. Shared with the cascade so the two cannot disagree about
        // which scopes exist.
        let scopes = try [ScopeID.all] + ThresholdService.containedScopes(of: .all, in: modelContext)

        for scope in scopes {
            let existing = try ThresholdService.effectivePosition(for: scope, in: modelContext)
            guard existing.markSortKey == .distantPast else { continue }
            guard let newest = try ThresholdService.newestItem(for: scope, in: modelContext) else { continue }

            try ThresholdService.setPosition(
                scope,
                to: newest.sortKey,
                deviceID: deviceID,
                in: modelContext
            )
        }
    }

    // MARK: - Sources

    public func upsertSources(_ sources: [IngestedSource], accountID: UUID) throws {
        // A title this run is about to rewrite must not be matched against by its old value.
        sourceTitles.removeAll(keepingCapacity: true)

        let existing = try modelContext.fetch(
            FetchDescriptor<CachedSource>(predicate: #Predicate { $0.accountID == accountID })
        )
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(sources.map(\.id))

        for source in sources {
            guard let row = byID[source.id] else {
                modelContext.insert(CachedSource(
                    id: source.id,
                    accountID: source.accountID,
                    kind: source.kind,
                    title: source.title,
                    homepageURLString: source.homepageURLString,
                    iconURLString: source.iconURLString,
                    folderName: source.folderName,
                    sortIndex: source.sortIndex
                ))
                continue
            }

            let folderChanged = row.folderName != source.folderName

            row.title = source.title
            row.homepageURLString = source.homepageURLString
            // Keep a previously discovered favicon if the server stops reporting one, rather than
            // flipping the row back to a generic symbol.
            row.iconURLString = source.iconURLString ?? row.iconURLString
            row.folderName = source.folderName
            row.sortIndex = source.sortIndex
            row.isSubscribed = true

            if folderChanged {
                // The item-level copy of the folder has to move too, or this feed's existing items
                // stay in the old folder's count while only new ones appear in the right place.
                try ThresholdService.updateFolderName(
                    source.folderName,
                    forSourceID: source.id,
                    in: modelContext
                )
            }
            byID[source.id] = row
        }

        // A source the server no longer lists is flagged, not deleted: its items and reading
        // position must survive an API hiccup that returns a short list.
        //
        // An *empty* list is not treated as a statement at all. It is the extreme case of that
        // hiccup and does the maximum damage — every feed disappears from the sidebar at once —
        // and a server can answer 200 with `{"subscriptions":[]}` for reasons that have nothing to
        // do with the user unsubscribing: a session that authenticated far enough to be allowed
        // through but not far enough to see their categories, for one. Unsubscribing everything on
        // that evidence is never the right call; the cost of ignoring it is that someone who
        // genuinely removes their last feed keeps seeing it until they remove the account.
        if !sources.isEmpty {
            for row in existing where !incomingIDs.contains(row.id) {
                row.isSubscribed = false
            }
        }

        // Also here, not only after an ingest run, so that a feed moved into a new folder does not
        // leave that folder counting its whole backlog until the next completed run.
        try seedUnmarkedScopes()

        try modelContext.save()
    }
}
