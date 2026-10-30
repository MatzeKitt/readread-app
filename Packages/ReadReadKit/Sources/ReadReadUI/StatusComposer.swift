import MastodonAPI
import Observation
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftUI

/// What a Mastodon action needs to put on screen, held at the window.
///
/// The things here are started from places that do not outlive them — a row's context menu, and a
/// row is recycled the moment it scrolls off, taking any sheet or dialog presented from it along
/// with it. So they are owned by the shell and presented there, exactly like ``MediaViewerModel``
/// and ``InAppBrowserModel``, and the menu's job is reduced to handing over what it was acting on.
///
/// One model for unrelated presentations because they share that reason for existing and nothing
/// else; splitting them would be several environment values and modifiers that are always
/// installed together.
@MainActor
@Observable
final class StatusComposer {

    /// A reply being written.
    ///
    /// Identified by a fresh id per opening rather than by the post, so answering the same post
    /// twice presents a composer twice rather than the second attempt doing nothing.
    struct ReplyDraft: Identifiable {

        let id = UUID()

        /// The post being answered. Held rather than re-fetched: the composer posts through
        /// ``AppServices/reply(_:to:as:)``, which needs the row itself.
        let item: CachedItem

        /// The widest a reply to this may be sent — see ``MastodonVisibility``.
        let parentVisibility: MastodonVisibility

        let authorName: String

        /// `user@host`, without the leading `@`.
        let authorHandle: String

        /// What the post says, for the composer to show above the field. A reply written without
        /// the post in front of you is a reply to what you remember it saying.
        let excerpt: String

        /// Handles to prefill, the author first, then everyone the post mentioned.
        ///
        /// Mastodon's own convention, and it is not decoration: a reply that drops the other
        /// participants' mentions removes them from the conversation without saying so.
        let mentions: [String]

        /// Minted once, here, and carried through every attempt to send this draft.
        ///
        /// The whole point is that it does **not** change on a retry — see
        /// ``StatusInteractions/Reply/idempotencyKey``. Putting it on the draft rather than on the
        /// send is what guarantees that: there is nowhere else for it to be regenerated.
        let idempotencyKey = UUID().uuidString
    }

    /// A mute waiting to be confirmed.
    struct MuteRequest: Identifiable {
        let id = UUID()
        let item: CachedItem
        let authorName: String
        let authorHandle: String
    }

    /// A reply subscription being made or changed.
    ///
    /// Here with the reply composer, for the same reason: it is started from places that do not
    /// outlive it — a sidebar row's context menu, and the reading pane's toolbar, which changes
    /// under it whenever the selection moves.
    struct SubscriptionDraft: Identifiable {

        let id = UUID()

        /// The subscription being edited, or nil for a new one.
        let editing: ReplySubscription?

        /// The account to follow it with. Nil lets the sheet choose; a post from the timeline
        /// fixes it to the account the post arrived in.
        var accountID: UUID?

        var urlString: String
        var title: String

        /// The post already looked up, when the draft starts from one. Saves the sheet a search
        /// request for a post the store already holds by its id.
        var target: ReplySubscriptionEditing.Target?
    }

    var replyDraft: ReplyDraft?
    var muteRequest: MuteRequest?
    var subscriptionDraft: SubscriptionDraft?

    /// Opens the composer, or answers false when the row cannot support one.
    ///
    /// The `Bool` is not decoration. Both of these depend on the row's stored payload decoding —
    /// a reply needs the parent's visibility and its mentions, neither of which is a column — and a
    /// menu item that silently does nothing when it does not is the worst way to fail. The caller
    /// turns a false into the same sentence every other unusable-row case produces.
    @discardableResult
    func reply(to item: CachedItem) -> Bool {
        guard let draft = Self.draft(for: item) else { return false }
        replyDraft = draft
        return true
    }

    @discardableResult
    func confirmMute(of item: CachedItem) -> Bool {
        guard let status = Self.status(for: item) else { return false }
        let author = status.displayStatus.account
        muteRequest = MuteRequest(
            item: item,
            authorName: author.bestDisplayName,
            authorHandle: author.acct
        )
        return true
    }

    func dismissReply() { replyDraft = nil }

    /// Opens the sheet for a new subscription, entered by link.
    func newSubscription(accountID: UUID?) {
        subscriptionDraft = SubscriptionDraft(editing: nil, accountID: accountID, urlString: "", title: "")
    }

    /// Opens the sheet for an existing subscription.
    func edit(_ subscription: ReplySubscription) {
        subscriptionDraft = SubscriptionDraft(
            editing: subscription,
            accountID: subscription.accountID,
            urlString: subscription.statusURLString,
            title: subscription.title,
            target: ReplySubscriptionEditing.Target(
                accountID: subscription.accountID,
                statusID: subscription.statusID,
                statusURLString: subscription.statusURLString
            )
        )
    }

    /// Opens the sheet for subscribing to a post in the timeline, or answers false when the row
    /// cannot support one — see ``reply(to:)`` for why that is a `Bool`.
    @discardableResult
    func subscribe(to item: CachedItem) -> Bool {
        guard let target = Self.subscriptionTarget(for: item), let status = Self.status(for: item) else {
            return false
        }
        let post = status.displayStatus
        subscriptionDraft = SubscriptionDraft(
            editing: nil,
            accountID: item.accountID,
            urlString: target.statusURLString,
            title: ReplySubscriptionEditing.suggestedTitle(
                authorName: post.account.bestDisplayName,
                text: HTMLText.plainText(from: post.content)
            ),
            target: target
        )
        return true
    }

    func dismissSubscription() { subscriptionDraft = nil }

    /// The post a row shows, as the account it arrived in knows it.
    ///
    /// The **displayed** status, as for every other action: a boost's own id names the act of
    /// boosting, which has no replies.
    static func subscriptionTarget(for item: CachedItem) -> ReplySubscriptionEditing.Target? {
        guard let status = status(for: item) else { return nil }
        let post = status.displayStatus
        return ReplySubscriptionEditing.Target(
            accountID: item.accountID,
            statusID: post.id.rawValue,
            statusURLString: post.url ?? post.uri
        )
    }

    func dismissMute() { muteRequest = nil }

    // MARK: - Building a draft

    /// Everything the composer needs, read out of the row's stored payload.
    ///
    /// Decoded here rather than taken from the denormalised columns because a reply needs things no
    /// column carries — the parent's visibility, and who it mentioned. That is affordable exactly
    /// because it happens once, when a reader chooses to answer a post; the columns exist for the
    /// work that happens per row while scrolling.
    static func draft(for item: CachedItem) -> ReplyDraft? {
        guard let status = status(for: item) else { return nil }

        let subject = status.displayStatus
        return ReplyDraft(
            item: item,
            parentVisibility: MastodonVisibility(statusValue: subject.visibility),
            authorName: subject.account.bestDisplayName,
            authorHandle: subject.account.acct,
            // A warned post's `title` is its warning, and its excerpt is empty. The post's own words
            // are what a reply answers, so they are quoted instead.
            excerpt: item.isBehindContentWarning
                ? HTMLText.truncating(HTMLText.plainText(from: subject.content), to: 320)
                : item.excerpt,
            mentions: mentions(of: subject)
        )
    }

    /// Who a reply should be addressed to: the author, then everyone they were talking to.
    ///
    /// Order matters and duplicates do not survive. The author leads because a reply is to them;
    /// the rest follow in the order the post itself listed them, which is the order the instance
    /// put them in.
    ///
    /// The acting account's own handle is *not* removed here, because which account is acting is
    /// not known until the composer's picker has been answered — and it can change while the reply
    /// is being written. That removal belongs to the composer; see `ReplyComposerSheet`.
    ///
    /// `nonisolated` because it reads its argument and nothing else. Left on the main actor with
    /// the rest of the class it could only be asserted from a main-actor test, which is a hop
    /// bought for nothing.
    nonisolated static func mentions(of status: MastodonStatus) -> [String] {
        var seen = Set<String>()
        var handles: [String] = []

        for handle in [status.account.acct] + status.mentions.map(\.acct) {
            let handle = AuthorMute.normalised(handle)
            guard !handle.isEmpty, seen.insert(handle).inserted else { continue }
            handles.append(handle)
        }
        return handles
    }

    private static func status(for item: CachedItem) -> MastodonStatus? {
        guard
            item.kind == .status,
            let payload = item.mastodonPayload
        else { return nil }
        return try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
    }
}
