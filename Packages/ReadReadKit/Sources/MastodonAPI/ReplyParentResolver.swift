import Foundation
import ReadReadModel
import ReadReadSupport

/// Finds the posts a batch of replies answer.
///
/// Shared by the two places that need it: ingest, which looks up the parents of the replies on each
/// page before writing them, and ``ReplyParentBackfill``, which catches the replies ingest could not
/// — ones stored before this existed, and ones whose lookup failed in a way worth retrying.
///
/// A parent is often already in hand. A thread somebody posts in parts arrives as a run of replies
/// to each other on the same page, so the caller passes what it has and only the rest go to the
/// network.
public struct ReplyParentResolver: Sendable {

    /// How many parents to fetch at once.
    ///
    /// More than one, because a page of forty posts can hold a dozen replies and fetching their
    /// parents one after another would add seconds to every refresh. Not many more, because these
    /// are requests to the reader's own instance on the back of a timeline fetch, and an instance
    /// that rate-limits answers a burst with 429s.
    static let maxConcurrentRequests = 4

    private let client: MastodonClient

    public init(client: MastodonClient) {
        self.client = client
    }

    /// What the instance said about one status.
    public enum Fetched: Sendable {
        case status(MastodonStatus)

        /// Deleted, hidden from this account, or answered with something that will not decode —
        /// all of which asking again would only repeat.
        case gone
    }

    /// Looks up each parent, from `known` where it can and from the instance where it cannot.
    ///
    /// - Parameters:
    ///   - parentIDs: The parents' ids on this instance.
    ///   - known: Statuses already in hand, keyed by their id.
    ///   - hasTimeRemaining: Consulted before each request. A background refresh has a deadline,
    ///     and a parent it did not get to is picked up by the backfill on a later run.
    /// - Returns: An answer for each id that got one. An id that is missing was not answered —
    ///   the request failed, or time ran out — and should be asked about again later.
    public func resolve(
        _ parentIDs: Set<String>,
        known: [String: MastodonStatus] = [:],
        hasTimeRemaining: @escaping @Sendable () -> Bool = { true }
    ) async -> [String: ReplyParentLookup] {
        var results: [String: ReplyParentLookup] = [:]
        var pending: Set<String> = []

        for id in parentIDs {
            if let status = known[id] {
                results[id] = Self.lookup(for: status)
            } else {
                pending.insert(id)
            }
        }

        for (id, fetched) in await fetch(pending, hasTimeRemaining: hasTimeRemaining) {
            switch fetched {
            case .status(let status): results[id] = Self.lookup(for: status)
            case .gone: results[id] = .unavailable
            }
        }

        return results
    }

    /// Fetches statuses by id, a few at a time.
    ///
    /// - Returns: An answer for each id that got one. A missing id is worth asking for again.
    public func fetch(
        _ ids: Set<String>,
        hasTimeRemaining: @escaping @Sendable () -> Bool = { true }
    ) async -> [String: Fetched] {
        var results: [String: Fetched] = [:]

        await withTaskGroup(of: (String, Fetched?).self) { group in
            // Sorted so the order requests go out in is a function of the input alone.
            var next = ids.sorted().makeIterator()

            func startNext() -> Bool {
                guard hasTimeRemaining(), !Task.isCancelled, let id = next.next() else { return false }
                group.addTask { [client] in
                    (id, await Self.fetch(MastodonStatusID(id), from: client))
                }
                return true
            }

            for _ in 0..<Self.maxConcurrentRequests {
                guard startNext() else { break }
            }

            for await (id, fetched) in group {
                if let fetched {
                    results[id] = fetched
                }
                _ = startNext()
            }
        }

        return results
    }

    /// One status from the instance, or nil when the answer is worth asking for again.
    private static func fetch(_ id: MastodonStatusID, from client: MastodonClient) async -> Fetched? {
        do {
            guard let status = try await client.status(id) else { return .gone }
            return .status(status)
        } catch MastodonError.unexpectedResponse {
            // The instance answered with something that will not decode. Asking again gets the same
            // body, and leaving the row unanswered would have the backfill fetch it on every
            // refresh for ever.
            return .gone
        } catch {
            // Offline, a timeout, a 5xx, a revoked token: all of them might go away.
            return nil
        }
    }

    /// The row's view of a parent or a quoted post, and the whole status for the reading pane.
    public static func lookup(for status: MastodonStatus, isQuote: Bool = false) -> ReplyParentLookup {
        let display = status.displayStatus

        // The warning instead of the post, exactly as a post's own list text is chosen in
        // `MastodonIngestPlanner.map`: the row is where nobody has opted in to seeing it yet.
        let hasWarning = !display.spoilerText.isEmpty
        let text = hasWarning
            ? display.spoilerText
            : HTMLText.truncating(HTMLText.plainText(from: display.content), to: 320)

        // Never empty, because empty is the column's sentinel for *no parent*.
        let name = display.account.bestDisplayName
        let parent = ReplyParent(
            authorName: name.isEmpty ? "@\(display.account.acct)" : name,
            authorHandle: display.account.acct,
            avatarURLString: display.account.avatarURLString,
            text: text,
            hasContentWarning: hasWarning,
            isQuote: isQuote
        )
        return .found(parent, payload: try? JSONEncoder.mastodon.encode(display))
    }

    /// What to show above a post, given what its reply parent's lookup found.
    ///
    /// A quoted post wins over a reply's parent. It is part of what the post says — the post's own
    /// text points at it — where the parent is the conversation around it, and the row has room for
    /// one. It also costs nothing: it arrives inside the quote.
    ///
    /// - Parameter replyParents: Lookups for reply parents, keyed by the parent's id.
    /// - Returns: Nil when there is nothing to record yet: not a reply and not a quote, or a reply
    ///   whose parent was not answered.
    public static func contextLookup(
        for status: MastodonStatus,
        replyParents: [String: ReplyParentLookup]
    ) -> ReplyParentLookup? {
        let display = status.displayStatus

        if let quote = display.quote {
            if let quoted = quote.shownStatus {
                return lookup(for: quoted, isQuote: true)
            }
            // A quote that may not be shown — pending, revoked, deleted — on a post that replies to
            // nothing: an answer, so the backfill's search for quote posts stops matching it. The
            // post's own "RE: <link>" line stays, and is the honest thing to show.
            if display.inReplyToId == nil {
                return .unavailable
            }
        }

        return display.inReplyToId.flatMap { replyParents[$0] }
    }

    /// Whether a post needs its reply parent fetched: a reply, unless a quote will take the slot.
    public static func needsReplyParent(_ status: MastodonStatus) -> Bool {
        let display = status.displayStatus
        return display.inReplyToId != nil && display.quote?.shownStatus == nil
    }
}
