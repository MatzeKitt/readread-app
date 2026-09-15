import Foundation
import SwiftData

/// A feed item held in the local cache.
///
/// Everything here is re-fetchable, so this store is disposable: it is pruned on a schedule and can
/// be rebuilt from the servers. Nothing a user *creates* lives on this model — Read Later lives in
/// `ReadLaterEntry` precisely so that marking an item for later survives cache pruning.
///
/// ## Why the keys are stored as raw strings
///
/// `sortKeyRaw` and `ingestKeyRaw` hold `SortKey.rawValue`, not `SortKey`. A SwiftData `#Predicate`
/// can only reference stored properties and can only compare primitives, and the entire threshold
/// design rests on `sortKeyRaw > mark` being expressible as a predicate so that counting unread
/// items is a `fetchCount` against an index instead of loading rows into memory.
@Model
public final class CachedItem {

    /// Globally unique, namespaced by provider and account:
    /// `freshrss:<accountUUID>:<hex>` or `mastodon:<accountUUID>:<statusID>`.
    ///
    /// Namespacing by account matters because the same article can legitimately appear under two
    /// FreshRSS accounts, and the FreshRSS entry ids would collide.
    #Unique<CachedItem>([\.id])

    // Sidebar counts issue one `fetchCount` per scope — potentially a hundred of them on every
    // change — so each must be answerable from an index rather than by scanning rows. The
    // composite covers per-source and per-folder counts; the plain `sortKeyRaw` index covers the
    // unified timeline and its count.
    #Index<CachedItem>(
        [\.sortKeyRaw],
        [\.sourceID, \.sortKeyRaw],
        [\.folderName, \.sortKeyRaw],
        [\.ingestKeyRaw]
    )

    public var id: String = ""

    /// `CachedSource.id` this item belongs to. A plain foreign key rather than a SwiftData
    /// relationship: ingest writes items in batches without needing the source object faulted in,
    /// and every query filters by id anyway.
    public var sourceID: String = ""

    public var accountID: UUID = UUID()

    /// The folder its source belongs to, denormalised from `CachedSource.folderName`.
    ///
    /// Duplicated deliberately. `@Query` builds its predicate in a view's initialiser, where there
    /// is no `ModelContext` to look up which sources are in a folder — so without this, selecting a
    /// folder could not be expressed as a query at all. It also turns the folder count from an
    /// `IN (…)` over potentially hundreds of source ids into a single index lookup.
    ///
    /// The cost is that moving a feed between folders must rewrite its items, which subscription
    /// sync does as an explicit batch update.
    public var folderName: String?

    /// `ItemKind.rawValue`. Raw so it is predicate-usable.
    public var kindRaw: String = ItemKind.article.rawValue

    public var title: String = ""
    public var authorName: String?

    /// `user@host`, shown under the display name on a status row.
    ///
    /// A column rather than something read out of ``mastodonPayload``, for exactly the reason the
    /// engagement counts are columns: the timeline draws it on every row, and decoding a status's
    /// full JSON per cell while scrolling is the work the precomputed `excerpt` exists to avoid.
    public var authorHandle: String?
    public var urlString: String?

    /// The full article HTML from FreshRSS, or the status HTML from Mastodon.
    public var contentHTML: String = ""

    /// Plain text, pre-rendered at ingest for the 3-line list excerpt.
    ///
    /// Precomputed deliberately: stripping HTML while scrolling would parse the same markup on
    /// every cell reuse, and `NSAttributedString`'s HTML importer is main-thread-only and far too
    /// slow to run per row.
    public var excerpt: String = ""

    /// When the item was published, as reported by the feed. Drives display and ordering.
    public var publishedAt: Date = Date.distantPast

    /// The timeline's sort field and the threshold comparison field.
    ///
    /// Built from when the item was *fetched*, not from `publishedAt` — see `ingestKeyRaw`, which
    /// it now equals. Publishers get their own dates wrong often enough that ordering by them
    /// broke the reading position outright; the reasoning is at the mapping site in
    /// `FreshRSSIngestPlanner.map`. `publishedAt` is still what the row displays.
    public var sortKeyRaw: String = ""

    /// `SortKey.rawValue` built from when the item *arrived* — FreshRSS `crawlTimeMsec`, i.e. the
    /// server's `date_added`, so it is identical on every device rather than being local wall time.
    ///
    /// This *is* the ordering, and `sortKeyRaw` is a copy of it. The two are kept as separate
    /// columns rather than collapsed into one because they answer separately: retention's age rule
    /// and the sort are the same measure today, and a later provider that does supply a trustworthy
    /// published date could order by it without moving retention. Mastodon has always had them
    /// equal — a status's `created_at` is the server's own timestamp, not the author's claim.
    public var ingestKeyRaw: String = ""

    /// Set when the item arrived sorting *below* its scope's marker.
    ///
    /// Such an item would otherwise be silently invisible: it lands beneath the threshold, where
    /// it reads as already-seen. It stays where it sorts, but is surfaced through the timeline's
    /// "older items arrived" affordance.
    ///
    /// Nearly vestigial now that ordering is by fetch time: a freshly fetched item sorts above any
    /// marker the reader has reached, so the case this guards against — a published date from
    /// below the fold — cannot arise from the feed's own dates any more. Kept because it still
    /// covers a server re-serving something with an old `date_added` after the marker moved past
    /// it, and because removing it would silently drop the only affordance for items that do land
    /// underneath.
    public var arrivedLate: Bool = false

    /// Whether the author marked the media as sensitive.
    ///
    /// Denormalised out of `mastodonPayload` for one reason: the timeline shows media inline, and
    /// deciding per row whether to blur it cannot mean decoding a JSON payload per row. Nil where
    /// it was never recorded — a store written before the column existed — which is why the
    /// timeline treats the *absence* of an answer as sensitive rather than as safe. `StatusBackfill`
    /// fills it in from the payload already stored.
    public var isSensitive: Bool?

    /// Favicon or avatar URL for the row, resolved at ingest.
    public var iconURLString: String?

    /// Whether the account this item came from is switched on.
    ///
    /// Denormalised from `AccountRecord.isEnabled` for the same reason as `folderName`: a `@Query`
    /// builds its predicate in a view's initialiser, where there is no context to ask which
    /// accounts are enabled — so without this, "hide a disabled account's items" could not be
    /// expressed as a query at all, and every count would have to be computed by hand.
    ///
    /// Kept as a separate flag from `isFilteredOut` rather than folded into it, because the two
    /// are owned by different things: filter rules recompute `isFilteredOut` in bulk, and would
    /// cheerfully un-hide a disabled account's items on the next pass.
    public var isAccountEnabled: Bool = true

    /// Whether a `FilterRule` currently hides this item. Stored rather than evaluated on read so
    /// timeline queries and every threshold count can exclude filtered items in the predicate.
    public var isFilteredOut: Bool = false

    public var attachments: [Attachment] = []

    /// How a status was received: replies, boosts and favourites, as of the last ingest.
    ///
    /// Stored as columns rather than read out of ``mastodonPayload`` because the timeline shows
    /// them on every row: decoding a status's full JSON per cell, while scrolling, is exactly the
    /// per-row work the precomputed `excerpt` exists to avoid.
    ///
    /// A snapshot, not live. They are as stale as the last refresh, which is the honest thing for
    /// a reader that never writes back — and they matter as a rough sense of reach, not as a
    /// live counter.
    public var replyCount: Int = 0
    public var reblogCount: Int = 0
    public var favouriteCount: Int = 0

    /// Who boosted this post into the timeline, when it arrived as a boost.
    ///
    /// A display name, denormalised out of ``mastodonPayload`` for the same reason the counts are:
    /// the list shows it on every boosted row, and a row must not decode a status's JSON to draw
    /// itself.
    ///
    /// Three states, and the third is why this is optional. Nil means *not known* — a row written
    /// before the column existed — and `StatusBackfill` resolves those from the payload already
    /// stored. An empty string means known not to be a boost, which is what the backfill writes for
    /// an ordinary post so it stops matching the search. A name means the post is a boost.
    public var boostedByName: String?

    /// Whether the reader's own account has favourited or boosted this post.
    ///
    /// Columns for the usual reason — a row draws itself from them — and optional for the usual
    /// one: nil means *not known*, which is a row written before these existed. `StatusBackfill`
    /// resolves those from the stored payload; nil renders the same as `false`, so the only cost
    /// of an unfilled row is being offered Like on something already liked, which the server
    /// treats as a no-op.
    ///
    /// Whose state it is matters. These belong to the account whose token fetched the post, so
    /// acting as a *different* account cannot update them — see `StatusInteractions`, which
    /// deliberately leaves them alone in that case rather than recording another account's answer
    /// against this row.
    public var isFavourited: Bool?
    public var isReblogged: Bool?

    /// The preview of the link a post points at, as scalar columns.
    ///
    /// Columns rather than one encoded ``LinkCard``, for the reason the engagement counts are
    /// columns: the timeline draws this on every row that has one, and a row must not run a
    /// `JSONDecoder` to draw itself. Rebuilt on read by ``linkCard``.
    ///
    /// ``cardURLString`` carries three states, and the third is what makes the whole thing
    /// affordable. Nil means *not examined* — a row written before these columns existed — and
    /// `StatusBackfill` resolves those from the payload already stored. An empty string means
    /// examined and there is no card, which is true of most posts; without that answer the
    /// backfill would re-decode every cardless status on every launch, for ever. A URL means there
    /// is a card. The same three states as ``boostedByName``, for the same reason.
    public var cardURLString: String?
    public var cardTitle: String?
    public var cardSummary: String?
    public var cardImageURLString: String?

    /// The status this one replies to, when it is a reply.
    ///
    /// Kept so the detail view knows a post sits inside a conversation before it has fetched
    /// anything — it can offer the thread, or not, without a speculative round trip.
    public var inReplyToStatusID: String?

    /// The article extracted from the item's own page, when the feed is set to load full pages.
    ///
    /// Cached on the item rather than fetched per view because the fetch is the expensive part —
    /// a whole page over the network — and re-reading an article, or arrowing back to it, must not
    /// pay for it twice.
    ///
    /// Nil means "not fetched"; ``fullPageFetchedAt`` is what distinguishes that from "fetched and
    /// found nothing usable", which is a permanent property of the page and must not be retried on
    /// every selection.
    public var fullPageHTML: String?
    public var fullPageFetchedAt: Date?

    /// The original Mastodon `Status`, JSON-encoded, for the native detail view.
    ///
    /// Kept as opaque `Data` rather than shredded into columns because only the detail view needs
    /// it, it is never queried, and Mastodon's status shape is far richer (polls, emoji, mentions,
    /// boost chains) than anything worth normalising into this schema.
    public var mastodonPayload: Data?

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
        arrivedLate: Bool = false,
        isSensitive: Bool? = nil,
        iconURLString: String? = nil,
        isFilteredOut: Bool = false,
        isAccountEnabled: Bool = true,
        replyCount: Int = 0,
        reblogCount: Int = 0,
        favouriteCount: Int = 0,
        boostedByName: String? = nil,
        isFavourited: Bool? = nil,
        isReblogged: Bool? = nil,
        linkCard: LinkCard? = nil,
        inReplyToStatusID: String? = nil,
        attachments: [Attachment] = [],
        mastodonPayload: Data? = nil,
        fullPageHTML: String? = nil,
        fullPageFetchedAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.accountID = accountID
        self.folderName = folderName
        kindRaw = kind.rawValue
        self.title = title
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.urlString = urlString
        self.contentHTML = contentHTML
        self.excerpt = excerpt
        self.publishedAt = publishedAt
        sortKeyRaw = sortKey.rawValue
        ingestKeyRaw = ingestKey.rawValue
        self.arrivedLate = arrivedLate
        self.isSensitive = isSensitive
        self.iconURLString = iconURLString
        self.isFilteredOut = isFilteredOut
        self.isAccountEnabled = isAccountEnabled
        self.replyCount = replyCount
        self.reblogCount = reblogCount
        self.favouriteCount = favouriteCount
        self.boostedByName = boostedByName
        self.isFavourited = isFavourited
        self.isReblogged = isReblogged
        // Assigned only for a status, and the asymmetry is the point: the setter writes the
        // empty-string sentinel for nil, which records the row as *examined and cardless* — the
        // right answer for a post with no link, and a meaningless one for an article, which has no
        // notion of a card for a backfill to go looking for.
        if kind == .status {
            self.linkCard = linkCard
        }
        self.inReplyToStatusID = inReplyToStatusID
        self.attachments = attachments
        self.mastodonPayload = mastodonPayload
        self.fullPageHTML = fullPageHTML
        self.fullPageFetchedAt = fullPageFetchedAt
    }

    // MARK: - Typed accessors

    /// Computed, so it is not persisted a second time; `kindRaw` remains the source of truth.
    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .article }
        set { kindRaw = newValue.rawValue }
    }

    public var sortKey: SortKey {
        get { SortKey(rawValue: sortKeyRaw) }
        set { sortKeyRaw = newValue.rawValue }
    }

    public var ingestKey: SortKey {
        get { SortKey(rawValue: ingestKeyRaw) }
        set { ingestKeyRaw = newValue.rawValue }
    }

    public var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    public var iconURL: URL? {
        iconURLString.flatMap(URL.init(string:))
    }

    /// The link preview, or nil when there is none — or when nothing has looked yet.
    ///
    /// Both of those read as "no card" here, deliberately: a row that has not been examined has
    /// nothing to show either way, and the alternative is a view that has to distinguish two kinds
    /// of absence it can do nothing about. `StatusBackfill` is what turns the second kind into the
    /// first. Setting it writes the empty-string sentinel for nil, so assigning `nil` records
    /// *examined, no card* rather than reverting the row to unexamined.
    public var linkCard: LinkCard? {
        get {
            guard let cardURLString, !cardURLString.isEmpty else { return nil }
            return LinkCard(
                urlString: cardURLString,
                title: cardTitle ?? "",
                summary: cardSummary ?? "",
                imageURLString: cardImageURLString
            )
        }
        set {
            cardURLString = newValue?.urlString ?? ""
            cardTitle = newValue?.title
            cardSummary = newValue?.summary
            cardImageURLString = newValue?.imageURLString
        }
    }
}
