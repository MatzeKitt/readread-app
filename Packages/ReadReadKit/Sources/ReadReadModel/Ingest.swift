import Foundation

/// An item ready to be written to the store, decoupled from any provider's wire format.
///
/// Providers map their own payloads onto this, so the persistence layer has no knowledge of
/// FreshRSS or Mastodon and the planners have no knowledge of SwiftData.
public struct IngestedItem: Sendable, Equatable {

    public var id: String
    public var sourceID: String
    public var accountID: UUID
    public var folderName: String?
    public var kind: ItemKind
    public var title: String
    public var authorName: String?

    /// `user@host` for a status. Nil for an article, which has no such thing.
    public var authorHandle: String?
    public var urlString: String?
    public var contentHTML: String
    public var excerpt: String
    public var publishedAt: Date
    public var sortKey: SortKey
    public var ingestKey: SortKey
    public var iconURLString: String?
    public var attachments: [Attachment]

    /// Whether the author marked the media sensitive. Nil for anything that has no such notion.
    public var isSensitive: Bool?
    public var mastodonPayload: Data?

    /// The preview of the link a post points at, when the instance has built one.
    ///
    /// Nil covers both "no link" and "the instance has not resolved one yet", which are the same
    /// thing to a reader. Only ever set on the status path; see ``LinkCard`` for why it is read
    /// from the timeline response rather than fetched.
    public var linkCard: LinkCard?

    /// Replies, boosts and favourites for a status. All zero for an article.
    public var engagement: StatusEngagement?

    /// The provider's own id for this item, in the form its cursor uses.
    ///
    /// Kept separate from `id` because `id` is namespaced for the local store while the cursor has
    /// to speak the server's dialect — for FreshRSS, the decimal entry id.
    public var providerID: String

    public init(
        id: String,
        sourceID: String,
        accountID: UUID,
        folderName: String? = nil,
        kind: ItemKind,
        title: String,
        authorName: String? = nil,
        authorHandle: String? = nil,
        urlString: String? = nil,
        contentHTML: String = "",
        excerpt: String = "",
        publishedAt: Date,
        sortKey: SortKey,
        ingestKey: SortKey,
        iconURLString: String? = nil,
        attachments: [Attachment] = [],
        isSensitive: Bool? = nil,
        mastodonPayload: Data? = nil,
        linkCard: LinkCard? = nil,
        engagement: StatusEngagement? = nil,
        providerID: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.accountID = accountID
        self.folderName = folderName
        self.kind = kind
        self.title = title
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.urlString = urlString
        self.contentHTML = contentHTML
        self.excerpt = excerpt
        self.publishedAt = publishedAt
        self.sortKey = sortKey
        self.ingestKey = ingestKey
        self.iconURLString = iconURLString
        self.attachments = attachments
        self.isSensitive = isSensitive
        self.mastodonPayload = mastodonPayload
        self.linkCard = linkCard
        self.engagement = engagement
        self.providerID = providerID
    }
}

/// How a status was received, and where it sits in a conversation.
///
/// A small struct rather than four more parameters on ``IngestedItem``, so that the article path —
/// which has none of this — passes `nil` and says so, instead of passing four zeroes that look
/// like a post nobody engaged with.
public struct StatusEngagement: Sendable, Equatable {

    public var replyCount: Int
    public var reblogCount: Int
    public var favouriteCount: Int

    /// The status being replied to, if any.
    public var inReplyToStatusID: String?

    /// The display name of whoever boosted this into the timeline, when it arrived as a boost.
    ///
    /// Part of *how it was received*, which is what this type is for: the same post reaches one
    /// reader directly and another through a boost, and only the wrapper knows which.
    public var boostedByName: String?

    /// Whether the reader's own account has already favourited or boosted this.
    ///
    /// Also *how it was received* — by an account that had already acted on it, or not — and it is
    /// what turns Like into Unlike. Nil where the server did not say, which for this app means a
    /// row written before these were read rather than an unauthenticated fetch.
    public var isFavourited: Bool?
    public var isReblogged: Bool?

    public init(
        replyCount: Int = 0,
        reblogCount: Int = 0,
        favouriteCount: Int = 0,
        inReplyToStatusID: String? = nil,
        boostedByName: String? = nil,
        isFavourited: Bool? = nil,
        isReblogged: Bool? = nil
    ) {
        self.replyCount = replyCount
        self.reblogCount = reblogCount
        self.favouriteCount = favouriteCount
        self.inReplyToStatusID = inReplyToStatusID
        self.boostedByName = boostedByName
        self.isFavourited = isFavourited
        self.isReblogged = isReblogged
    }
}

/// A source discovered during ingest, ready to be written to the store.
public struct IngestedSource: Sendable, Equatable {

    public var id: String
    public var accountID: UUID
    public var kind: ItemKind
    public var title: String
    public var homepageURLString: String?
    public var iconURLString: String?
    public var folderName: String?
    public var sortIndex: Int

    public init(
        id: String,
        accountID: UUID,
        kind: ItemKind,
        title: String,
        homepageURLString: String? = nil,
        iconURLString: String? = nil,
        folderName: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.title = title
        self.homepageURLString = homepageURLString
        self.iconURLString = iconURLString
        self.folderName = folderName
        self.sortIndex = sortIndex
    }
}

/// A snapshot of one stream's two ingest cursors.
///
/// See ``SyncCursor`` for why there are two and what goes wrong when they are conflated.
public struct IngestCursorState: Sendable, Equatable {

    /// The stop line: the newest provider id confirmed by a **completed** run. Empty means nothing
    /// has ever been ingested, so the first walk runs to its page budget.
    public var highestSeenID: String

    /// Where an in-progress descending walk left off, as the provider's continuation token.
    public var resumeContinuation: String

    /// Whether a walk is part-way through. Distinguishes "no walk in progress" from "a walk that
    /// happens to be starting at the top of the stream".
    public var isWalkInProgress: Bool

    /// Highest provider id seen during the walk in progress, promoted into `highestSeenID` only
    /// when the run completes.
    public var pendingHighestSeenID: String

    /// The history window the stop line was established under. See ``SyncCursor/historyWindowDays``.
    public var historyWindowDays: Int

    public init(
        highestSeenID: String = "",
        resumeContinuation: String = "",
        isWalkInProgress: Bool = false,
        pendingHighestSeenID: String = "",
        historyWindowDays: Int = 0
    ) {
        self.highestSeenID = highestSeenID
        self.resumeContinuation = resumeContinuation
        self.isWalkInProgress = isWalkInProgress
        self.pendingHighestSeenID = pendingHighestSeenID
        self.historyWindowDays = historyWindowDays
    }

    public static let fresh = IngestCursorState()
}

/// How much work one run may do.
public struct IngestBudget: Sendable {

    /// Hard cap on pages fetched in one run, so a first-time import of a huge backlog drains
    /// across several runs instead of running unbounded.
    public var maxPages: Int

    /// Consulted before starting each page. Returning `false` ends the run cleanly, with the
    /// cursor persisted, rather than being cut off mid-page.
    ///
    /// A closure rather than a deadline so tests can make the budget expire at an exact point
    /// without depending on wall-clock timing.
    public var hasTimeRemaining: @Sendable () -> Bool

    public init(maxPages: Int, hasTimeRemaining: @escaping @Sendable () -> Bool = { true }) {
        self.maxPages = maxPages
        self.hasTimeRemaining = hasTimeRemaining
    }

    /// Generous, for a foreground refresh on a Mac.
    public static let foreground = IngestBudget(maxPages: 50)

    /// For a `BGAppRefreshTask`, which gets roughly 30 seconds.
    ///
    /// The soft deadline is deliberately short of that: the run must have time to persist its
    /// cursor and re-submit the background task after the last page, and being killed before that
    /// is what makes a background refresh silently stop firing.
    public static func background(
        seconds: Double = 20,
        clock: ContinuousClock = ContinuousClock()
    ) -> IngestBudget {
        let deadline = clock.now.advanced(by: .seconds(seconds))
        return IngestBudget(maxPages: 20) { clock.now < deadline }
    }
}

/// What a run did.
public struct IngestOutcome: Sendable, Equatable {

    public var itemsWritten: Int
    public var pagesFetched: Int

    /// Whether the walk reached its stop line or the end of the stream.
    ///
    /// The gate on promoting the cursor, on pruning, and on publishing the badge. A run that ends
    /// any other way leaves all three untouched.
    public var isComplete: Bool

    /// Whether the run stopped because it ran out of pages or time rather than finishing.
    public var stoppedForBudget: Bool

    /// Items that arrived carrying a published date below their scope's marker.
    public var lateArrivals: Int

    public init(
        itemsWritten: Int = 0,
        pagesFetched: Int = 0,
        isComplete: Bool = false,
        stoppedForBudget: Bool = false,
        lateArrivals: Int = 0
    ) {
        self.itemsWritten = itemsWritten
        self.pagesFetched = pagesFetched
        self.isComplete = isComplete
        self.stoppedForBudget = stoppedForBudget
        self.lateArrivals = lateArrivals
    }
}

/// Where ingest writes to.
///
/// An abstraction rather than a direct `ModelContext` dependency for two reasons. It keeps the
/// paging and cursor logic — the part with the subtle bugs — testable without a store or a
/// simulator. And `ModelContext` is not `Sendable`, so a planner holding one would be pinned to a
/// single actor.
public protocol IngestSink: Sendable {

    /// The current cursors for a stream.
    func cursorState(accountID: UUID, streamKey: String) async throws -> IngestCursorState

    /// Writes one page's items and advances the resume cursor **in a single transaction**.
    ///
    /// Atomicity is the point: if items were committed without the cursor, a crash would re-fetch
    /// and re-insert them; if the cursor were committed without the items, they would be skipped
    /// forever.
    ///
    /// - Returns: How many of the items were newly seen as late arrivals.
    @discardableResult
    func commit(
        items: [IngestedItem],
        accountID: UUID,
        streamKey: String,
        resumeContinuation: String,
        pendingHighestSeenID: String
    ) async throws -> Int

    /// Promotes `pendingHighestSeenID` into the stop line and clears the walk state.
    ///
    /// Called only on a completed run.
    ///
    /// - Parameter historyWindowDays: The window the run was fetched under, stored alongside the
    ///   stop line so a later change to the setting can be detected.
    func completeRun(
        accountID: UUID,
        streamKey: String,
        highestSeenID: String,
        historyWindowDays: Int
    ) async throws

    /// Records that a run ended without finishing, leaving the stop line untouched.
    func abandonRun(accountID: UUID, streamKey: String) async throws

    /// Upserts the sources discovered from a subscription list, and returns the folder each source
    /// belongs to so items can be tagged as they are ingested.
    func upsertSources(_ sources: [IngestedSource], accountID: UUID) async throws
}
