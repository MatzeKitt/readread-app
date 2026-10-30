import Foundation
import ReadReadModel
import SwiftData

/// Looks up the parents of replies, and the quoted posts of quote posts, that ingest did not.
///
/// Quote posts end up here for two reasons. Ones stored before quotes were read: the status type
/// had no `quote` field, so the stored payload lost it, and the post itself has to be fetched again
/// to find out what it quotes. And ones whose quote is still pending on this instance, which the
/// quoting post's own server is asked about — see `ReplyParentResolver.lookUpPendingQuote`. Both
/// are recognised by the "RE: <link>" paragraph Mastodon writes into every quote post for apps that
/// cannot show one, which is marked `class="quote-inline"`.
///
/// Two kinds of reply end up here. Ones stored before parents were looked up at all, which the walk
/// will never visit again — it stops at the first id it already knows, so without this the posts
/// above replies would appear only on replies published after the update. And ones whose lookup
/// failed in a way worth retrying: offline, a timeout, a background run out of time.
///
/// From the network, unlike `StatusBackfill`, because a reply's stored payload names its parent
/// and does not contain it. The store is asked first, since the parent is often a post from the
/// same timeline.
@ModelActor
public actor ReplyParentBackfill {

    /// How many replies to look at per run, and separately how many quote posts.
    ///
    /// Bounded because each one can be a request, and this runs after every refresh. The newest go
    /// first, which are the ones at the top of the timeline where the reader is looking; a large
    /// backlog drains a page at a time over the following refreshes.
    public static let defaultLimit = 40

    /// How long after a post is published a pending quote on it is still asked about again.
    ///
    /// For as long as neither this instance nor the quoting post's own server has an answer — the
    /// approval can take minutes to arrive. Bounded, because a quote that is never decided would
    /// otherwise be asked about after every refresh for as long as the post is kept.
    static let pendingQuoteRetryWindow: TimeInterval = 24 * 60 * 60

    /// Looks up what to show above one account's replies and quote posts that have nothing recorded.
    ///
    /// Quote posts first: a post that both quotes and replies shows the quote, so its parent is
    /// only worth fetching once the quote has turned out not to be showable.
    ///
    /// - Parameters:
    ///   - now: What a pending quote's age is measured against. See ``pendingQuoteRetryWindow``.
    ///   - originClient: A client for the server a quoting post comes from, which is asked about a
    ///     quote still pending here. Anonymous unless a test says otherwise.
    /// - Returns: How many posts got an answer, a post to show or a definite *none*.
    @discardableResult
    public func fill(
        accountID: UUID,
        client: MastodonClient,
        limit: Int = defaultLimit,
        now: Date = .now,
        originClient: @escaping @Sendable (URL) -> MastodonClient = { MastodonClient(instanceURL: $0, accessToken: nil) },
        hasTimeRemaining: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Int {
        try rebuildWarnedParents(accountID: accountID)

        let quotes = try await fillQuotes(
            accountID: accountID,
            client: client,
            limit: limit,
            now: now,
            originClient: originClient,
            hasTimeRemaining: hasTimeRemaining
        )
        let replies = try await fillReplies(
            accountID: accountID,
            client: client,
            limit: limit,
            hasTimeRemaining: hasTimeRemaining
        )
        return quotes + replies
    }

    /// Rebuilds parents behind a content warning that were recorded with the warning as their text.
    ///
    /// From the stored payload, so without a request: a warned parent used to be recorded as its
    /// warning alone, and the row now shows its text with the warning underneath. One without a
    /// payload is looked up again instead, by the passes after this one.
    ///
    /// - Returns: How many rows were rebuilt or reopened.
    @discardableResult
    func rebuildWarnedParents(accountID: UUID) throws -> Int {
        let rows = try modelContext.fetch(FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.replyParentHasContentWarning
                    && $0.replyParentContentWarning == nil
            }
        ))
        guard !rows.isEmpty else { return 0 }

        for row in rows {
            if let payload = row.replyParentPayload,
               let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload) {
                row.record(ReplyParentResolver.lookup(for: status, isQuote: row.replyParentIsQuote))
            } else {
                row.replyParentAuthorName = nil
                row.replyParentHasContentWarning = false
            }
        }
        try modelContext.save()
        return rows.count
    }

    /// Re-fetches quote posts that have no answer yet, to find what they quote.
    private func fillQuotes(
        accountID: UUID,
        client: MastodonClient,
        limit: Int,
        now: Date,
        originClient: @escaping @Sendable (URL) -> MastodonClient,
        hasTimeRemaining: @escaping @Sendable () -> Bool
    ) async throws -> Int {
        let statusKind = ItemKind.status.rawValue
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.kindRaw == statusKind
                    && $0.replyParentAuthorName == nil
                    && $0.contentHTML.contains("quote-inline")
            },
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return 0 }

        // The *displayed* status's id: a boosted quote post is the boost's row, and the boost
        // wrapper quotes nothing.
        var statusIDs: [String: String] = [:]
        var answered = 0
        for row in rows {
            guard
                let payload = row.mastodonPayload,
                let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
            else {
                // Nothing to ask the instance about, and left unanswered it would match for ever.
                row.record(.unavailable)
                answered += 1
                continue
            }
            statusIDs[row.id] = status.displayStatus.id.rawValue
        }

        let resolver = ReplyParentResolver(client: client)
        let fetched = await resolver.fetch(Set(statusIDs.values), hasTimeRemaining: hasTimeRemaining)

        var pending: [(row: CachedItem, status: MastodonStatus)] = []
        for row in rows {
            guard let statusID = statusIDs[row.id], let answer = fetched[statusID] else { continue }

            switch answer {
            case .gone:
                row.record(.unavailable)
                answered += 1

            case .status(let status):
                let display = status.displayStatus
                if let lookup = ReplyParentResolver.contextLookup(for: status, replyParents: [:]) {
                    row.record(lookup)
                    answered += 1
                } else if display.quote?.isPending == true, display.inReplyToId == nil {
                    pending.append((row, status))
                } else if display.quote == nil, display.inReplyToId == nil {
                    // Quotes nothing after all — the paragraph was typed by hand, or an edit took
                    // the quote away. An answer, so the row leaves this search.
                    row.record(.unavailable)
                    answered += 1
                }
                // Otherwise a reply whose quote cannot be shown: left for the reply pass below,
                // which shows its parent instead.
            }
        }

        // One after another rather than a few at a time like the fetches above: there are rarely
        // more than one or two, and each is two requests, one of them to a server that owes this
        // reader nothing.
        for (row, status) in pending {
            guard hasTimeRemaining(), !Task.isCancelled else { break }

            switch await resolver.lookUpPendingQuote(of: status, originClient: originClient) {
            case .found(let lookup):
                row.record(lookup)
                answered += 1
            case .refused:
                row.record(.unavailable)
                answered += 1
            case .undecided:
                // Asked about again on the next run, until the window runs out.
                if now.timeIntervalSince(status.displayStatus.createdAt) >= Self.pendingQuoteRetryWindow {
                    row.record(.unavailable)
                    answered += 1
                }
            }
        }

        if answered > 0 {
            try modelContext.save()
        }
        return answered
    }

    private static let reopenedQuotesKey = "com.kittmedia.ReadRead.pendingQuotesReopened"

    /// Clears the *nothing to show* recorded on quote posts, once, so the quote pass looks at each
    /// of them again.
    ///
    /// Before pending quotes were asked about again, a quote post fetched before its approval
    /// arrived — or from an instance that never verified the approval — was recorded as having
    /// nothing to show, and kept only its "RE: <link>" line. The row
    /// does not say which recorded answers those were, so every quote post's is cleared. The ones
    /// that really have nothing to show — refused, revoked, deleted — are fetched once more and
    /// recorded again, a page at a time over the following refreshes.
    ///
    /// - Returns: How many rows were reopened.
    @discardableResult
    public static func reopenUnshownQuotesIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Int {
        guard !defaults.bool(forKey: reopenedQuotesKey) else { return 0 }

        let statusKind = ItemKind.status.rawValue
        let nothingToShow = ""
        let rows = try context.fetch(FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.kindRaw == statusKind
                    && $0.replyParentAuthorName == nothingToShow
                    && $0.contentHTML.contains("quote-inline")
            }
        ))
        for row in rows {
            row.replyParentAuthorName = nil
        }
        if !rows.isEmpty {
            try context.save()
        }

        defaults.set(true, forKey: reopenedQuotesKey)
        return rows.count
    }

    /// Looks up parents for replies that have none recorded.
    private func fillReplies(
        accountID: UUID,
        client: MastodonClient,
        limit: Int,
        hasTimeRemaining: @escaping @Sendable () -> Bool
    ) async throws -> Int {
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate {
                $0.accountID == accountID
                    && $0.inReplyToStatusID != nil
                    && $0.replyParentAuthorName == nil
            },
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let replies = try modelContext.fetch(descriptor)
        guard !replies.isEmpty else { return 0 }

        let parentIDs = Set(replies.compactMap(\.inReplyToStatusID))
        let lookups = await ReplyParentResolver(client: client).resolve(
            parentIDs,
            known: try storedStatuses(parentIDs, accountID: accountID),
            hasTimeRemaining: hasTimeRemaining
        )

        var answered = 0
        for reply in replies {
            guard let parentID = reply.inReplyToStatusID, let lookup = lookups[parentID] else { continue }
            reply.record(lookup)
            answered += 1
        }

        if answered > 0 {
            try modelContext.save()
        }
        return answered
    }

    /// Parents that are themselves in the store, decoded from their payloads.
    ///
    /// By item id, which for a post that arrived directly is built from its status id. A parent
    /// that arrived as somebody's *boost* is filed under the boost's id instead, and is simply not
    /// found here — the instance is asked for it, which costs a request and gets the same answer.
    private func storedStatuses(_ parentIDs: Set<String>, accountID: UUID) throws -> [String: MastodonStatus] {
        let itemIDs = parentIDs.map { SourceIdentifier.mastodonItem(accountID: accountID, statusID: $0) }
        let rows = try modelContext.fetch(FetchDescriptor<CachedItem>(
            predicate: #Predicate { itemIDs.contains($0.id) }
        ))

        var statuses: [String: MastodonStatus] = [:]
        for row in rows {
            guard
                let payload = row.mastodonPayload,
                let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
            else { continue }
            let display = status.displayStatus
            statuses[display.id.rawValue] = display
        }
        return statuses
    }
}
