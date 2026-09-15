import Foundation
import ReadReadModel
import ReadReadSupport

/// Walks a Mastodon home timeline and writes what it finds, one page at a time, resumably.
///
/// Structurally the same two-cursor walk as the FreshRSS planner, for the same reason: a run that
/// is cut short must not raise the stop line past pages it never fetched. The differences are all
/// in the provider:
///
/// - Pagination is `max_id` taken from the `Link` header, not an opaque continuation token.
/// - Ids are **opaque strings** compared length-then-lexically, never parsed as integers.
/// - There is no separate server-insertion timestamp, so `ingestKey` is the timeline entry's own
///   `created_at`.
public struct MastodonIngestPlanner: Sendable {

    public static let homeStreamKey = "home"

    private let client: MastodonClient
    private let sink: any IngestSink
    private let accountID: UUID
    private let pageSize: Int

    public init(
        client: MastodonClient,
        sink: any IngestSink,
        accountID: UUID,
        pageSize: Int = MastodonClient.maxTimelineLimit
    ) {
        self.client = client
        self.sink = sink
        self.accountID = accountID
        self.pageSize = pageSize
    }

    /// Registers the home timeline as a sidebar source.
    public func refreshSource(title: String = "Home") async throws {
        try await sink.upsertSources([
            IngestedSource(
                id: SourceIdentifier.mastodonHome(accountID: accountID),
                accountID: accountID,
                kind: .status,
                title: title,
                sortIndex: 0
            ),
        ], accountID: accountID)
    }

    /// Walks the home timeline, newest-first, until it reaches known statuses, the end of the
    /// timeline, the history window, or the budget.
    ///
    /// - Parameter historyWindowDays: How far back to fetch, in days; `0` for everything. Unlike
    ///   FreshRSS there is no server-side bound to ask for — `timelines/home` takes only id
    ///   cursors — so the cutoff is applied to what comes back, and the walk stops on the first
    ///   page that reaches past it. Timelines are strictly id-ordered and Mastodon ids are
    ///   time-ordered, so "past it" really is the end of what matters.
    public func ingest(
        budget: IngestBudget = .foreground,
        historyWindowDays: Int = HistoryWindow.unlimited,
        now: Date = .now
    ) async throws -> IngestOutcome {
        let streamKey = Self.homeStreamKey
        let state = try await sink.cursorState(accountID: accountID, streamKey: streamKey)

        let cutoff = HistoryWindow.cutoff(forDays: historyWindowDays, now: now)

        // See `FreshRSSIngestPlanner.ingest` — a changed window discards the stop line for one run,
        // because widening it would otherwise fetch nothing.
        let windowChanged = state.historyWindowDays != historyWindowDays

        let stopLine = (state.highestSeenID.isEmpty || windowChanged)
            ? nil
            : MastodonStatusID(state.highestSeenID)

        // Only resume mid-walk if one was actually in progress; a leftover cursor from a completed
        // run would start this walk part-way down and skip everything newer.
        var maxID: String? = state.isWalkInProgress && !windowChanged && !state.resumeContinuation.isEmpty
            ? state.resumeContinuation
            : nil

        var pendingHighest: MastodonStatusID? = state.isWalkInProgress && !state.pendingHighestSeenID.isEmpty
            ? MastodonStatusID(state.pendingHighestSeenID)
            : nil

        var outcome = IngestOutcome()

        while true {
            guard outcome.pagesFetched < budget.maxPages, budget.hasTimeRemaining() else {
                outcome.stoppedForBudget = true
                break
            }
            try Task.checkCancellation()

            let page = try await client.homeTimeline(limit: pageSize, maxID: maxID)
            outcome.pagesFetched += 1

            for status in page.statuses {
                if pendingHighest == nil || status.id > pendingHighest! {
                    pendingHighest = status.id
                }
            }

            var reachedStopLine = false
            var reachedCutoff = false
            var fresh: [MastodonStatus] = []
            for status in page.statuses {
                if let stopLine, status.id <= stopLine {
                    reachedStopLine = true
                    break
                }
                if let cutoff, status.createdAt < cutoff {
                    // Ordered newest-first, so everything after this is older too.
                    reachedCutoff = true
                    break
                }
                fresh.append(status)
            }

            let items = fresh.map(map)
            let nextContinuation = page.nextMaxID ?? ""

            let lateArrivals = try await sink.commit(
                items: items,
                accountID: accountID,
                streamKey: streamKey,
                resumeContinuation: nextContinuation,
                pendingHighestSeenID: pendingHighest?.rawValue ?? ""
            )
            outcome.itemsWritten += items.count
            outcome.lateArrivals += lateArrivals

            // No `next` link means there is nothing older. An empty page means the same.
            if reachedStopLine || reachedCutoff || page.nextMaxID == nil || page.statuses.isEmpty {
                outcome.isComplete = true
                break
            }
            maxID = page.nextMaxID
        }

        if outcome.isComplete {
            try await sink.completeRun(
                accountID: accountID,
                streamKey: streamKey,
                highestSeenID: pendingHighest?.rawValue ?? state.highestSeenID,
                historyWindowDays: historyWindowDays
            )
        } else {
            try await sink.abandonRun(accountID: accountID, streamKey: streamKey)
        }

        return outcome
    }

    // MARK: - Mapping

    /// Maps a status onto the store's shape.
    func map(_ status: MastodonStatus) -> IngestedItem {
        // A boost's own timestamp and id place it in the timeline, but the content and author
        // shown belong to the status it wraps.
        let display = status.displayStatus
        let itemID = SourceIdentifier.mastodonItem(accountID: accountID, statusID: status.id.rawValue)

        // `created_at` of the timeline entry serves as both keys. Mastodon exposes no separate
        // server-insertion time, and inventing one from local wall time would make ordering and
        // late-arrival detection disagree between devices.
        let millis = status.createdAt.millisecondsSinceEpoch
        let plainText = HTMLText.plainText(from: display.content)

        // A content warning must win in the list. Showing the post's text beside its own warning
        // would defeat the warning entirely — the list is exactly where the user has not opted in
        // to seeing it yet.
        let hasWarning = !display.spoilerText.isEmpty
        let listText = hasWarning ? display.spoilerText : plainText

        return IngestedItem(
            id: itemID,
            sourceID: SourceIdentifier.mastodonHome(accountID: accountID),
            accountID: accountID,
            folderName: nil,
            kind: .status,
            // Untruncated. A status has no title of its own — this *is* its text — and the
            // timeline shows it in full, so cutting it at 200 characters here made "show the whole
            // post" impossible however the row was written. Mastodon bounds post length itself.
            title: listText,
            authorName: display.account.bestDisplayName,
            authorHandle: display.account.acct,
            urlString: display.url ?? display.uri,
            contentHTML: display.content,
            excerpt: hasWarning ? "" : HTMLText.truncating(plainText, to: 320),
            publishedAt: status.createdAt,
            sortKey: SortKey(millis: millis, id: itemID),
            ingestKey: SortKey(millis: millis, id: itemID),
            iconURLString: display.account.avatarURLString,
            attachments: display.mediaAttachments.compactMap(Self.attachment),
            // Read from the *displayed* status, like the counts and the media: a boost's wrapper
            // carries its own `sensitive` and it is not the one describing this media.
            isSensitive: display.sensitive,
            // Stored so the native detail view can render polls, custom emoji, media and boost
            // attribution without another round trip.
            mastodonPayload: try? JSONEncoder.mastodon.encode(status),
            // From the displayed status, like the media and the counts: a boost wrapper carries no
            // card of its own, so reading it from the outer status would drop the preview from
            // every boosted link in the timeline.
            linkCard: Self.linkCard(from: display.card),
            // Taken from the displayed status, not the wrapper: a boost's own counts are always
            // zero, so reading them from the outer status would report every boosted post in the
            // timeline as having reached nobody.
            engagement: StatusEngagement(
                replyCount: display.repliesCount,
                reblogCount: display.reblogsCount,
                favouriteCount: display.favouritesCount,
                inReplyToStatusID: display.inReplyToId,
                // From the **wrapper**, which is the one exception to everything above coming from
                // the displayed status: the boost is the outer status, and its account is the only
                // place the booster's name exists.
                boostedByName: status.boostedBy?.bestDisplayName,
                // From the displayed status again: what the reader has favourited is the post, and
                // a boost wrapper's own flags are about the act of boosting.
                isFavourited: display.favourited,
                isReblogged: display.reblogged
            ),
            providerID: status.id.rawValue
        )
    }

    /// Maps Mastodon's preview card onto the store's shape.
    ///
    /// Shared with `StatusBackfill` for the same reason ``attachment(from:)`` is: it fills this in
    /// for rows written before the columns existed, and two copies of the mapping could disagree
    /// about what a card is.
    ///
    /// Returns nil for a card with nothing to show. Instances do produce those — a link whose
    /// target answered with no usable metadata still gets a `PreviewCard` with empty strings in it
    /// — and storing one would put an empty box under the post. Nil here and nil for "no card"
    /// are the same fact to a reader.
    public static func linkCard(from card: MastodonPreviewCard?) -> LinkCard? {
        guard let card else { return nil }
        let mapped = LinkCard(
            urlString: card.url,
            title: card.title,
            summary: card.description,
            imageURLString: card.image
        )
        return mapped.isShowable ? mapped : nil
    }

    /// Shared with `StatusBackfill`, which rebuilds attachments for rows written before they
    /// carried a preview URL, and with the views, which map a thread's statuses as they arrive
    /// from the network. One mapping, so none of them can disagree about what a thumbnail is —
    /// the view's own copy had no preview URL at all, which left every video in a conversation
    /// trying to draw its MP4 as a still image.
    public static func attachment(from media: MastodonMediaAttachment) -> Attachment? {
        // `url` is null while the server is still processing an upload. Storing a row with no URL
        // would give the detail view a permanently broken tile.
        guard let urlString = media.fullURLString, let url = URL(string: urlString) else { return nil }

        let original = media.meta?.original
        return Attachment(
            url: url,
            kind: kind(fromMastodonType: media.type),
            mimeType: media.type,
            describedAs: media.description,
            blurhash: media.blurhash,
            width: original?.width,
            height: original?.height,
            previewURLString: media.thumbnailURLString
        )
    }

    /// Maps Mastodon's own attachment type vocabulary, which is not a MIME type.
    private static func kind(fromMastodonType type: String) -> Attachment.Kind {
        switch type {
        case "image": .image
        case "video": .video
        case "gifv": .gifv
        case "audio": .audio
        default: .other
        }
    }
}
