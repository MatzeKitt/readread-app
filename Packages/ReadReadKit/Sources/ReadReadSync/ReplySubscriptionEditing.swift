import Foundation
import ReadReadModel
import SwiftData

/// Every way the reader changes a reply subscription, each written together with its sync record.
///
/// Gathered in one place for the reason ``SyncOutbox`` names its mutations: a change that saved
/// without its outbox row would stay on one device for good. Each of these writes both into the
/// caller's context and saves neither, so the caller's single `save()` commits the pair or nothing.
public enum ReplySubscriptionEditing {

    /// The post a subscription follows, as its account's instance knows it.
    public struct Target: Sendable, Equatable {

        public var accountID: UUID

        /// The post's id on that instance.
        public var statusID: String

        public var statusURLString: String

        public init(accountID: UUID, statusID: String, statusURLString: String) {
            self.accountID = accountID
            self.statusID = statusID
            self.statusURLString = statusURLString
        }
    }

    /// Subscribes to a post, or hands back the subscription that already follows it.
    ///
    /// One subscription per post and account. A second would walk the same conversation twice and
    /// put the same replies in two lists, and the second list could only ever be a copy of the
    /// first.
    @discardableResult
    public static func subscribe(
        to target: Target,
        title: String,
        in context: ModelContext
    ) throws -> ReplySubscription {
        if let existing = try subscription(following: target.statusID, accountID: target.accountID, in: context) {
            return existing
        }

        let subscription = ReplySubscription(
            accountID: target.accountID,
            statusID: target.statusID,
            statusURLString: target.statusURLString,
            title: Self.trimmed(title)
        )
        context.insert(subscription)
        try SyncOutbox.record(subscription, in: context)
        return subscription
    }

    /// Changes what a subscription is called, and optionally which post it follows.
    ///
    /// - Parameter target: The post to follow from now on, or nil to keep the current one. A
    ///   different post starts its conversation from scratch: the replies the old one brought in
    ///   are let go of, and the next refresh walks the new one as a first walk.
    public static func update(
        _ subscription: ReplySubscription,
        title: String,
        target: Target? = nil,
        in context: ModelContext
    ) throws {
        if let target,
           target.statusID != subscription.statusID || target.accountID != subscription.accountID {
            try ReplySubscription.forgetConversation(of: subscription, in: context)
            subscription.accountID = target.accountID
            subscription.statusID = target.statusID
        }
        if let target {
            subscription.statusURLString = target.statusURLString
        }
        subscription.title = Self.trimmed(title)
        subscription.updatedAt = .now
        try SyncOutbox.record(subscription, in: context)
    }

    /// Unsubscribes. The replies stay in the home timeline; see ``ReplySubscription/remove(_:in:)``.
    public static func unsubscribe(_ subscription: ReplySubscription, in context: ModelContext) throws {
        let id = subscription.id
        try ReplySubscription.remove(subscription, in: context)
        try SyncOutbox.recordReplySubscriptionDeletion(id: id, in: context)
    }

    /// The subscription following a post, if there is one.
    public static func subscription(
        following statusID: String,
        accountID: UUID,
        in context: ModelContext
    ) throws -> ReplySubscription? {
        var descriptor = FetchDescriptor<ReplySubscription>(
            predicate: #Predicate { $0.statusID == statusID && $0.accountID == accountID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// What to call a subscription nobody has named: the author, and the start of what they said.
    ///
    /// Enough to recognise the conversation in the sidebar, where the row has a line to itself.
    public static func suggestedTitle(authorName: String, text: String) -> String {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !words.isEmpty else { return authorName }

        let limit = 60
        let excerpt = words.count > limit
            ? String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
            : words
        return authorName.isEmpty ? excerpt : "\(authorName): \(excerpt)"
    }

    private static func trimmed(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
