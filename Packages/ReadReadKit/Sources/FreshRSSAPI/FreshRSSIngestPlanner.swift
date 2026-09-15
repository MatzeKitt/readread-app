import Foundation
import ReadReadModel
import ReadReadSupport

/// Walks a FreshRSS stream and writes what it finds, one page at a time, resumably.
///
/// ## The walk
///
/// The reading-list stream is ordered by **entry id descending**, and FreshRSS entry ids are
/// microsecond insertion timestamps. So the stream is ordered by when items *arrived*, and a newly
/// inserted item always appears at the top however old its published date. Two things follow, and
/// the whole design rests on them:
///
/// - Paging downwards until the first already-known id **cannot miss** an item.
/// - The `continuation` token is an exact resume point, because the server applies it as an
///   exclusive `id_max`.
///
/// This governs *fetching* only. The app's timeline is ordered by published date, which is a
/// separate concern handled by `SortKey`.
///
/// ## Why two cursors
///
/// `highestSeenID` — the stop line — is promoted only when a whole run completes. If it advanced
/// page by page, an interrupted run would raise the stop line to the newest item it had seen while
/// the older pages it never fetched still sat below it. The next run would stop immediately at the
/// new line and everything in that gap would be skipped **permanently**, with no error and nothing
/// to notice.
public struct FreshRSSIngestPlanner: Sendable {

    /// The stream key used for the reading list's cursor row.
    public static let readingListStreamKey = "reading-list"

    private let client: GReaderClient
    private let sink: any IngestSink
    private let accountID: UUID
    private let pageSize: Int

    public init(
        client: GReaderClient,
        sink: any IngestSink,
        accountID: UUID,
        pageSize: Int = 100
    ) {
        self.client = client
        self.sink = sink
        self.accountID = accountID
        self.pageSize = pageSize
    }

    // MARK: - Subscriptions

    /// Refreshes the subscription list and returns each feed's folder, for tagging items.
    ///
    /// Run before an item walk so a newly subscribed feed's items land in the right folder
    /// immediately rather than appearing unfiled until the next refresh.
    @discardableResult
    public func refreshSubscriptions() async throws -> [String: String?] {
        let subscriptions = try await client.subscriptions()

        var sources: [IngestedSource] = []
        var foldersByStreamID: [String: String?] = [:]

        for (index, subscription) in subscriptions.enumerated() {
            let sourceID = SourceIdentifier.freshRSS(accountID: accountID, streamID: subscription.id)
            sources.append(IngestedSource(
                id: sourceID,
                accountID: accountID,
                kind: .article,
                title: subscription.title,
                homepageURLString: subscription.homepageURLString,
                iconURLString: subscription.iconURLString,
                folderName: subscription.folderName,
                sortIndex: index
            ))
            foldersByStreamID[subscription.id] = subscription.folderName
        }

        try await sink.upsertSources(sources, accountID: accountID)
        return foldersByStreamID
    }

    // MARK: - Item walk

    /// Walks the reading list, newest-first, until it reaches known items, the end of the stream,
    /// or the budget.
    ///
    /// - Parameter folders: Feed stream id to folder name, from ``refreshSubscriptions()``. Passed
    ///   in rather than looked up per item so a page needs no extra queries.
    /// - Parameter historyWindowDays: How far back to fetch, in days; `0` for everything. Applied
    ///   as the endpoint's own `ot` bound, so the server does the filtering and the walk simply
    ///   runs out of pages — far cheaper than downloading a decade of archive to discard it here.
    public func ingest(
        budget: IngestBudget = .foreground,
        folders: [String: String?] = [:],
        historyWindowDays: Int = HistoryWindow.unlimited,
        now: Date = .now
    ) async throws -> IngestOutcome {
        let streamKey = Self.readingListStreamKey
        let state = try await sink.cursorState(accountID: accountID, streamKey: streamKey)

        let cutoff = HistoryWindow.cutoff(forDays: historyWindowDays, now: now)

        // A changed window discards the stop line for one run.
        //
        // Without this the setting only works in one direction. The walk stops at the first id it
        // already has, and FreshRSS ids are insertion timestamps — so an article published *and*
        // inserted five weeks ago sits permanently below the stop line, and widening the window
        // from a week to a month would fetch nothing new and look broken. Re-walking costs one
        // full pass, at the moment the user asked for more history, which is when they expect it.
        let windowChanged = state.historyWindowDays != historyWindowDays

        // The stop line comes from the last *completed* run. Nil on a first-ever ingest, which
        // then runs to the page budget.
        let stopLine = (state.highestSeenID.isEmpty || windowChanged)
            ? nil
            : GReaderItemID(state.highestSeenID)

        // Resume mid-walk only if one was actually in progress. A stale continuation from a
        // completed run would silently start the next walk part-way down the stream, skipping
        // everything newer.
        var continuation: String? = state.isWalkInProgress && !windowChanged && !state.resumeContinuation.isEmpty
            ? state.resumeContinuation
            : nil

        var pendingHighest: GReaderItemID? = state.isWalkInProgress && !state.pendingHighestSeenID.isEmpty
            ? GReaderItemID(state.pendingHighestSeenID)
            : nil

        var outcome = IngestOutcome()

        while true {
            guard outcome.pagesFetched < budget.maxPages, budget.hasTimeRemaining() else {
                outcome.stoppedForBudget = true
                break
            }
            try Task.checkCancellation()

            let page = try await client.streamContents(
                .readingList,
                count: pageSize,
                order: .newestFirst,
                continuation: continuation,
                notOlderThan: cutoff
            )
            outcome.pagesFetched += 1

            // Track the run's high-water mark from every item seen, not just the first: the server
            // is free to return them in any order within a page, and taking the max is robust to
            // that where taking `items.first` would not be.
            for item in page.items {
                if pendingHighest == nil || item.id > pendingHighest! {
                    pendingHighest = item.id
                }
            }

            // Descending order means that once one item is at or below the stop line, so is every
            // item after it — in this page and in the whole remaining stream.
            var reachedStopLine = false
            var fresh: [GReaderItem] = []
            for item in page.items {
                if let stopLine, item.id <= stopLine {
                    reachedStopLine = true
                    break
                }
                fresh.append(item)
            }

            let items = fresh.map { map($0, folders: folders) }
            let nextContinuation = page.continuation ?? ""

            // Items and cursor in one transaction: see `IngestSink.commit`.
            let lateArrivals = try await sink.commit(
                items: items,
                accountID: accountID,
                streamKey: streamKey,
                resumeContinuation: nextContinuation,
                pendingHighestSeenID: pendingHighest?.decimalString ?? ""
            )
            outcome.itemsWritten += items.count
            outcome.lateArrivals += lateArrivals

            // A missing continuation is how the server says "that was the last page".
            if reachedStopLine || page.continuation == nil || page.items.isEmpty {
                outcome.isComplete = true
                break
            }
            continuation = page.continuation
        }

        if outcome.isComplete {
            // Only now is it safe to raise the stop line. If nothing was seen at all, keep the
            // previous line rather than clearing it.
            try await sink.completeRun(
                accountID: accountID,
                streamKey: streamKey,
                highestSeenID: pendingHighest?.decimalString ?? state.highestSeenID,
                historyWindowDays: historyWindowDays
            )
        } else {
            try await sink.abandonRun(accountID: accountID, streamKey: streamKey)
        }

        return outcome
    }

    // MARK: - Mapping

    /// Maps a wire item onto the store's shape.
    func map(_ item: GReaderItem, folders: [String: String?]) -> IngestedItem {
        let streamID = item.originStreamID ?? ""
        let sourceID = SourceIdentifier.freshRSS(accountID: accountID, streamID: streamID)

        // Fetch time drives display order; the published date is kept for display only.
        //
        // Ordering by the *feed's* published date means trusting a number the publisher controls
        // and frequently gets wrong, and a wrong one is not a cosmetic problem: a real feed on
        // this account published items dated five days into the future, which under published
        // ordering pinned them to the top of the timeline permanently and — far worse — parked
        // the reading position on a future date, so every genuinely new item sorted *below* the
        // marker and was never counted as new. Absent and epoch-zero dates fail the same way at
        // the other end.
        //
        // `crawlTimeMsec` is the server's own `date_added`, which is also what FreshRSS itself
        // orders the reading list by (`id DESC`, and an entry id is its insertion timestamp), so
        // this makes the app's timeline agree with the server's rather than inventing a third
        // order. It is a server value, so it is identical on every device — local wall time would
        // not be, and two devices would disagree about the order.
        let publishedMillis = item.published.map { Int64($0) * 1_000 }
        let ingestMillis = item.ingestMillis
        let resolvedPublished = publishedMillis ?? ingestMillis ?? 0
        let resolvedIngest = ingestMillis ?? publishedMillis ?? 0

        let itemID = SourceIdentifier.freshRSSItem(accountID: accountID, itemID: item.id.storageString)
        let html = item.contentHTML

        return IngestedItem(
            id: itemID,
            sourceID: sourceID,
            accountID: accountID,
            folderName: folders[streamID] ?? nil,
            kind: .article,
            title: item.title ?? "",
            authorName: item.author,
            urlString: item.linkURLString,
            contentHTML: html,
            // Computed once here rather than while scrolling: the list must never parse HTML per
            // row, and this is the only place that already has the markup in hand.
            excerpt: HTMLText.excerpt(from: html),
            publishedAt: Date(millisecondsSinceEpoch: resolvedPublished),
            sortKey: SortKey(millis: resolvedIngest, id: itemID),
            ingestKey: SortKey(millis: resolvedIngest, id: itemID),
            attachments: item.enclosure?.compactMap(Self.attachment) ?? [],
            providerID: item.id.decimalString
        )
    }

    private static func attachment(from enclosure: GReaderEnclosure) -> Attachment? {
        guard let href = enclosure.href, let url = URL(string: href) else { return nil }
        return Attachment(
            url: url,
            kind: Attachment.kind(fromMIMEType: enclosure.type),
            mimeType: enclosure.type,
            byteCount: enclosure.length
        )
    }
}
