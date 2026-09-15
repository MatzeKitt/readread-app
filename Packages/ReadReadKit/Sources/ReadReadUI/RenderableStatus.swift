import Foundation
import MastodonAPI
import ReadReadModel
import ReadReadSupport

/// One status, in the shape the views render.
///
/// Exists because a thread mixes two sources: the post being read comes from the **store**, as a
/// `CachedItem`, while the posts around it come straight from the **network**, as `MastodonStatus`.
/// Rendering each from its own type would mean two status views that must be kept looking
/// identical — and the first thing to drift would be the content warning, which is the one thing
/// that must not.
struct RenderableStatus: Identifiable, Sendable {

    var id: String
    var authorName: String

    /// `user@host`, shown under the display name. Nil for a status assembled from the store, which
    /// does not keep the handle separately.
    var authorHandle: String?

    var avatarURLString: String?
    var contentHTML: String

    /// Plain-text fallback, used when the HTML will not parse.
    var plainText: String

    var createdAt: Date
    var url: URL?
    var attachments: [Attachment]

    /// The author marked the media as sensitive.
    var isSensitive: Bool

    /// The content warning. Empty when there is none.
    var spoilerText: String

    /// Who boosted this into the timeline, when it arrived as a boost.
    var boostedBy: String?

    var replyCount: Int
    var reblogCount: Int
    var favouriteCount: Int

    /// Whether the reader's own account has favourited or boosted this.
    ///
    /// Carried so that every card in a conversation can show it, not only the post being read: the
    /// ancestors and replies come straight off the network, where Mastodon answers an authenticated
    /// request with the asking account's state on every status it returns. There is no column for
    /// those — they are never stored — so this is the only place they could come from.
    ///
    /// Defaulted, because the memberwise initialiser is also used for a row with no payload, where
    /// the answer comes from the store instead.
    var isFavourited: Bool = false
    var isReblogged: Bool = false

    /// Whether the body starts hidden behind a warning.
    var isHiddenByDefault: Bool { !spoilerText.isEmpty }

    var isReply: Bool

    /// The attached poll, when there is one.
    var poll: RenderablePoll?

    /// The preview of the link the post points at, when the instance built one.
    ///
    /// The same card the timeline row draws — see ``LinkCard``, which is Mastodon's own
    /// `PreviewCard`, resolved by the instance from the target page's oEmbed endpoint or its
    /// OpenGraph tags. Carried here rather than read from the store's columns at the point of
    /// display, because half the cards in a thread belong to posts that were never stored: the
    /// ancestors and replies come straight off the network, and there is no row to read.
    var linkCard: LinkCard?

    /// Custom emoji used in the content and the display name, keyed by shortcode.
    var emojis: [String: URL]

    /// Whether the status's own id on its instance is recoverable.
    ///
    /// False for a row with no stored payload — an item from an older build, or one whose payload
    /// will not decode. Without the id there is no conversation to ask for, so the affordance has
    /// to be hidden rather than offered and then failing.
    var canLoadConversation: Bool

    /// Whether it is worth offering to load the conversation.
    ///
    /// A post with no replies and no parent has no thread, and offering one would be a button that
    /// does nothing.
    var hasConversation: Bool { canLoadConversation && (replyCount > 0 || isReply) }
}

/// The post being read, decoded once instead of once per redraw.
///
/// ``RenderableStatus/init(_:)-(CachedItem)`` decodes the stored Mastodon payload, and its own
/// documentation says the decode "happens once, for the one post being read". It did not: the
/// reading pane reached it through a computed property, so a full `JSONDecoder` pass over the
/// status ran on every body evaluation — twice, in fact, once for the card and once for the
/// navigation title — and the pane re-evaluates whenever the conversation loads, whenever a text
/// size preference moves, and whenever it is re-laid out.
///
/// One entry, because there is one post being read. The other posts in a thread arrive from the
/// network already in this shape and never come through here.
///
/// Keyed on the item's id alone, which is the same bargain ``StatusTextCache`` makes: an edited
/// post is re-ingested under a new revision, and the only way to serve something stale is for the
/// payload of the post currently on screen to be rewritten underneath it.
@MainActor
enum RenderableStatusCache {

    private static var cachedID: String?
    private static var cached: RenderableStatus?

    static func status(for item: CachedItem) -> RenderableStatus {
        if let cached, cachedID == item.id { return cached }

        let status = RenderableStatus(item)
        cachedID = item.id
        cached = status
        return status
    }
}

extension RenderableStatus {

    /// From the store.
    ///
    /// The richest fields — the poll, the custom emoji, the mention list — have no column on
    /// `CachedItem`, so they are recovered from the stored payload when it is there. That decode
    /// happens once, for the one post being read, which is why it is acceptable here and not in a
    /// timeline row. The few things the list needs per row *are* columns, and the branch below
    /// falls back to them.
    init(_ item: CachedItem) {
        let status = item.mastodonPayload.flatMap { data in
            try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: data)
        }

        if let status {
            self.init(status, boostedBy: status.boostedBy?.bestDisplayName)
            // The store's own id, not the status's: this is what the timeline selects by, and a
            // mismatch would break scrolling to the focused post.
            id = item.id
            return
        }

        // No payload — an older row, or an article misrouted here. Everything below is what the
        // store keeps for any item, so the post still renders rather than showing a blank pane.
        //
        // Delegating to the memberwise initialiser rather than assigning the fields one by one:
        // Swift will not let one branch of an initialiser delegate while another assigns members.
        self.init(
            id: item.id,
            authorName: item.authorName ?? String(localized: "Unknown"),
            authorHandle: nil,
            avatarURLString: item.iconURLString,
            contentHTML: item.contentHTML,
            plainText: item.excerpt,
            createdAt: item.publishedAt,
            url: item.url,
            attachments: item.attachments,
            isSensitive: false,
            spoilerText: "",
            // From the column, which is the one richer field a payload-less row can still answer:
            // it is stored for the timeline, so the reading pane may as well agree with the row
            // the reader tapped rather than dropping the attribution on the way in.
            boostedBy: item.boostedByName.flatMap { $0.isEmpty ? nil : $0 },
            replyCount: item.replyCount,
            reblogCount: item.reblogCount,
            favouriteCount: item.favouriteCount,
            isFavourited: item.isFavourited ?? false,
            isReblogged: item.isReblogged ?? false,
            isReply: item.inReplyToStatusID != nil,
            poll: nil,
            // From the columns, like the boost attribution above: `StatusBackfill` fills these in
            // for posts that predate them, so a payload-less row can still show its card.
            linkCard: item.linkCard,
            emojis: [:],
            canLoadConversation: false
        )
    }

    /// From the network.
    init(_ status: MastodonStatus, boostedBy: String? = nil) {
        let display = status.displayStatus

        id = display.id.rawValue
        authorName = display.account.bestDisplayName
        authorHandle = display.account.acct
        avatarURLString = display.account.avatarURLString
        contentHTML = display.content
        plainText = HTMLText.plainText(from: display.content)
        createdAt = display.createdAt
        // Written as one initialiser rather than `(a ?? b).flatMap(URL.init)`: that form made the
        // compiler promote its way to `Optional.flatMap`, which left the `uri` fallback dead —
        // a status without a `url` had no "open in browser" link despite carrying a usable `uri`.
        url = URL(string: display.url ?? display.uri)
        attachments = display.mediaAttachments.compactMap(Attachment.init(mastodon:))
        isSensitive = display.sensitive
        spoilerText = display.spoilerText
        self.boostedBy = boostedBy ?? status.boostedBy?.bestDisplayName
        // From the displayed status: a boost wrapper's own counts are always zero.
        replyCount = display.repliesCount
        reblogCount = display.reblogsCount
        favouriteCount = display.favouritesCount
        // Nil where the instance omitted them, which for this app means a payload stored before
        // they were read rather than an unauthenticated request. False is the safe reading: it
        // offers Like on a post that may already be liked, which the server absorbs as a no-op.
        isFavourited = display.favourited ?? false
        isReblogged = display.reblogged ?? false
        isReply = display.inReplyToId != nil
        canLoadConversation = true
        poll = display.poll.map(RenderablePoll.init)
        // From the *displayed* status, so a boost shows the card of the post it carries rather
        // than the wrapper's — the wrapper has none. The ingest planner reads it the same way.
        linkCard = MastodonIngestPlanner.linkCard(from: display.card)
        // The account's emoji as well as the status's: a display name is where custom emoji turn
        // up most, and Mastodon lists those on the account rather than on the post.
        emojis = Self.emojiURLs(display.emojis + (display.account.emojis ?? []))
    }

    /// Custom emoji keyed by shortcode, skipping any whose URL will not parse.
    private static func emojiURLs(_ emojis: [MastodonCustomEmoji]) -> [String: URL] {
        var result: [String: URL] = [:]
        for emoji in emojis {
            // The animated `url` rather than `staticUrl`: a still frame is the fallback the
            // reduce-motion setting should choose, not the default everyone gets.
            guard let url = URL(string: emoji.url) else { continue }
            result[emoji.shortcode] = url
        }
        return result
    }
}

extension Attachment {

    /// Maps a Mastodon attachment, skipping one the server is still processing.
    ///
    /// Delegates to the ingest planner's mapping rather than repeating it, so a thread's media
    /// renders exactly like the stored post's — including the preview URL, which the copy that
    /// used to live here did not carry.
    init?(mastodon media: MastodonMediaAttachment) {
        guard let mapped = MastodonIngestPlanner.attachment(from: media) else { return nil }
        self = mapped
    }
}

/// A poll, as this app can show it.
///
/// Results only. ReadRead never writes to any server it reads from, so there is no voting here —
/// which also means the shape is simpler than Mastodon's: no own-votes, no ballot state, just what
/// the poll currently says.
struct RenderablePoll: Sendable, Equatable, Identifiable {

    struct Option: Sendable, Equatable, Identifiable {
        var id: Int
        var title: String

        /// Nil while the poll is running on an instance that hides running tallies, which is the
        /// default. Distinct from zero: "not saying" and "nobody" are different answers.
        var votes: Int?
    }

    var id: String
    var options: [Option]
    var totalVotes: Int
    var isExpired: Bool
    var allowsMultiple: Bool
    var expiresAt: Date?

    /// Whether any tally is being shown at all.
    var showsResults: Bool { options.contains { $0.votes != nil } }

    /// An option's share of the vote, or nil when there is nothing to show.
    ///
    /// Divides by the largest option rather than by the total: in a multiple-choice poll the
    /// options sum to more than `totalVotes`, and using the total there produces bars wider than
    /// the row they sit in.
    func share(of option: Option) -> Double? {
        guard let votes = option.votes else { return nil }
        let ceiling = allowsMultiple
            ? (options.compactMap(\.votes).max() ?? 0)
            : totalVotes
        guard ceiling > 0 else { return 0 }
        return min(1, Double(votes) / Double(ceiling))
    }

    /// An option's percentage of the total, for the label beside it.
    func percentage(of option: Option) -> Double? {
        guard let votes = option.votes, totalVotes > 0 else { return option.votes == nil ? nil : 0 }
        return Double(votes) / Double(totalVotes)
    }

    init(_ poll: MastodonPoll) {
        id = poll.id
        options = poll.options.enumerated().map { index, option in
            Option(id: index, title: option.title, votes: option.votesCount)
        }
        totalVotes = poll.votesCount
        isExpired = poll.expired
        allowsMultiple = poll.multiple
        expiresAt = poll.expiresAt
    }
}
