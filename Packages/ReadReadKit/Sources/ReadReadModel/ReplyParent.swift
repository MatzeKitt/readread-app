import Foundation

/// The post a reply answers or a quote post quotes, in the shape a timeline row draws it.
///
/// A reply on its own is half a conversation — "Yes, exactly" means nothing without what it says
/// yes to — so the row shows the post above it. A quote post is the same half, and gets the same
/// treatment: the quoted post above it, in place of the "RE: <link>" line Mastodon writes into the
/// post for apps that cannot show quotes.
///
/// A quoted post arrives inside the quote and needs no request. A reply's parent is fetched while
/// the reply is ingested rather than when the row appears, for two reasons. A row that grew a parent a second after it was drawn
/// would push everything below it down the list while somebody was reading it, in a timeline whose
/// whole design is that the reading position stays put. And it would cost a request per reply on
/// every launch, where this costs one per reply, once.
///
/// A plain value, denormalised onto ``CachedItem`` as scalar columns and rebuilt on read, for the
/// reason ``LinkCard`` is: a timeline row must not run a `JSONDecoder` to draw itself. The whole
/// parent status is kept beside it, as ``CachedItem/replyParentPayload``, for the reading pane.
public struct ReplyParent: Hashable, Sendable {

    public var authorName: String

    /// `user@host`. Nil when the instance did not say, which it always does in practice.
    public var authorHandle: String?

    public var avatarURLString: String?

    /// What the row prints: the parent's text as plain text — or, when the parent is behind a
    /// content warning, the warning and nothing else.
    ///
    /// Decided here rather than at the point of display, because getting it wrong prints a post
    /// its author hid into somebody else's row. Ingest makes the identical choice for a post's own
    /// list text; see `MastodonIngestPlanner.map`.
    public var text: String

    /// Whether ``text`` is a content warning rather than the post.
    public var hasContentWarning: Bool

    /// Whether this is the post being quoted rather than the post being replied to.
    ///
    /// The two are drawn alike, and part ways in the reading pane: a loaded conversation replaces
    /// a reply's parent, since its last ancestor *is* that parent, but says nothing about a quote.
    public var isQuote: Bool

    public init(
        authorName: String,
        authorHandle: String? = nil,
        avatarURLString: String? = nil,
        text: String,
        hasContentWarning: Bool = false,
        isQuote: Bool = false
    ) {
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.avatarURLString = avatarURLString
        self.text = text
        self.hasContentWarning = hasContentWarning
        self.isQuote = isQuote
    }
}

/// What looking for a reply's parent, or a quote post's quoted post, found.
///
/// Two answers, and the absence of one is a third: an ``IngestedItem`` whose lookup is nil was not
/// looked up at all — it is not a reply, the request failed in a way worth retrying, or the run
/// ran out of time — and the store keeps whatever it already had.
public enum ReplyParentLookup: Hashable, Sendable {

    /// The parent, and its whole status as the instance sent it, for the reading pane.
    case found(ReplyParent, payload: Data?)

    /// The instance answered, and there is no parent to show: it was deleted, or this account is
    /// not allowed to see it. Recorded, so nothing asks again.
    case unavailable
}
