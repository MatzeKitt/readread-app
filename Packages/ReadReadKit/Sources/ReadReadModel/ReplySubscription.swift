import Foundation
import SwiftData

/// A Mastodon post whose replies the reader has asked to follow.
///
/// Each refresh fetches the post's conversation and writes every reply into the account's home
/// timeline, the way mentions are written: under the reply's own item id, so a reply that also
/// arrives through the home timeline is the same row rather than a second copy. What marks the row
/// as belonging here is ``CachedItem/replySubscriptionID``, and that column is what the
/// subscription's own sidebar list is drawn from.
///
/// Created by the reader and synced, like a filter rule. Unlike the items it brings in, losing it
/// to a cache prune would lose something the reader made, so it lives in a model of its own.
@Model
public final class ReplySubscription {

    #Unique<ReplySubscription>([\.id])
    public var id: UUID = UUID()

    /// The Mastodon account whose instance is asked for the replies.
    ///
    /// The same on every device, because account ids are derived from what identifies the account
    /// rather than minted per device — see `AccountIdentity`. That is what lets this sync at all.
    public var accountID: UUID = UUID()

    /// The post's id **on that account's instance**.
    ///
    /// Resolved once, when the subscription is made, and synced with it: the same account on
    /// another device asks the same instance, which files the post under the same id. Resolving it
    /// again on every refresh would cost a search request per subscription for an answer that
    /// cannot change.
    public var statusID: String = ""

    /// The post's public URL, which is what the reader entered or what the post links to.
    ///
    /// Kept beside the id because it is the only name for the post that every instance agrees on,
    /// and because it is what "Open Post" opens.
    public var statusURLString: String = ""

    /// What the reader calls this subscription in the sidebar.
    public var title: String = ""

    public var createdAt: Date = Date.now

    /// When the reader last changed it. Last writer wins on this, as on a filter rule.
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        statusID: String,
        statusURLString: String,
        title: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.statusID = statusID
        self.statusURLString = statusURLString
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    public var statusURL: URL? {
        URL(string: statusURLString)
    }

    /// The cursor stream its replies are walked under. One per subscription, so each keeps its own
    /// stop line.
    public var streamKey: String {
        Self.streamKey(for: id)
    }

    public static func streamKey(for id: UUID) -> String {
        "replies:\(id.uuidString)"
    }

    /// The scope its sidebar row reads.
    public var scope: ScopeID {
        .replySubscription(id)
    }

    // MARK: - Removing

    /// Removes a subscription and lets go of what it brought in.
    ///
    /// The replies stay in the home timeline, since that is where they were written and the reader
    /// may be in the middle of reading them there. Only the mark tying each one to this
    /// subscription is cleared.
    ///
    /// Does not save, and does not queue a tombstone: the caller does both, in the same
    /// transaction, the way every synced mutation is written.
    public static func remove(_ subscription: ReplySubscription, in context: ModelContext) throws {
        try forgetConversation(of: subscription, in: context)
        context.delete(subscription)
    }

    /// Lets go of the replies a subscription has brought in, and of the walk that found them.
    ///
    /// For removing a subscription, and for pointing one at a different post: the old post's
    /// replies are not part of the new one's conversation, and the reply ids its cursor remembers
    /// would hide replies the new one has. Without the cursor, the next walk is a first walk, so
    /// subscribing to the same post again brings its replies back.
    ///
    /// Does not save.
    public static func forgetConversation(of subscription: ReplySubscription, in context: ModelContext) throws {
        let id = subscription.id
        let items = try context.fetch(FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.replySubscriptionID == id }
        ))
        for item in items {
            item.replySubscriptionID = nil
        }

        let key = SyncCursor.key(accountID: subscription.accountID, streamKey: subscription.streamKey)
        try context.delete(model: SyncCursor.self, where: #Predicate { $0.key == key })
    }

    /// Every subscription, in the order the sidebar lists them.
    public static func all(in context: ModelContext) throws -> [ReplySubscription] {
        try context.fetch(FetchDescriptor<ReplySubscription>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
    }

    /// The subscription with this id, if this device has it.
    public static func find(_ id: UUID, in context: ModelContext) throws -> ReplySubscription? {
        var descriptor = FetchDescriptor<ReplySubscription>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
