import Foundation
import SwiftData

/// Clearing a muted account's posts out of the local store.
///
/// Muting is a server-side action: the instance stops putting that person's posts into the home
/// timeline, and the next refresh simply brings fewer of them. That leaves the posts *already*
/// fetched sitting in the list, which is the half a reader would call a bug — you mute someone
/// because you do not want to see them, and everything you could see at the moment you did it stays
/// exactly where it was.
///
/// ## Why the rows are deleted rather than hidden
///
/// `isFilteredOut` is the obvious alternative and it does not work. It is owned by the filter
/// engine, which recomputes it — at ingest for every item it touches, and in a batch pass whenever
/// a rule changes — from the rules alone. A mute is not a rule, so the next pass would clear the
/// flag and the posts would come back with no way to tell why. The Filtered Items list would also
/// show them meanwhile, under a heading that says which rule hid each row, with nothing to name.
///
/// Deleting is safe here in a way it would not be elsewhere: `CachedItem` is a cache, the store is
/// rebuilt from the servers, and Read Later entries are self-contained snapshots that survive
/// pruning — so a muted person's post the reader had already saved stays saved. The one thing that
/// does not come back is the *old* posts, if the reader later unmutes: the ingest walk stops at the
/// first id it already knows, so it will not re-fetch them. That is a real limit and it is the
/// price of the immediacy; the alternative is a mute that appears not to work.
public enum AuthorMute {

    /// Removes every cached post by one account, within one of the reader's accounts.
    ///
    /// Scoped to `accountID` on purpose. A handle is fediverse-wide, but a mute is not: it is a
    /// statement to one instance about one reader's timeline. Somebody muted on the account they
    /// arrived in should keep appearing in a *second* account's timeline until that account mutes
    /// them too — anything else would be this app inventing a global mute the servers do not have.
    ///
    /// Matched on the handle rather than the instance's account id, because the handle is what rows
    /// carry: `CachedItem.authorHandle` is `acct`, denormalised at ingest so the timeline can draw
    /// it without decoding a payload per row. The id is only known where a payload has just been
    /// decoded, which is the acting side of this, not the sweeping side.
    ///
    /// Boosts are covered by the same match and deliberately so: `authorHandle` is the *displayed*
    /// status's author, so a muted person's post is removed however it arrived in the timeline,
    /// including when somebody else boosted it in.
    ///
    /// - Returns: How many rows went, so the caller can say nothing happened when nothing did.
    @discardableResult
    public static func removeItems(
        byAuthorHandle handle: String,
        accountID: UUID,
        in context: ModelContext
    ) throws -> Int {
        let handle = normalised(handle)
        guard !handle.isEmpty else { return 0 }

        let statusKind = ItemKind.status.rawValue
        let descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { item in
                item.accountID == accountID
                    && item.kindRaw == statusKind
                    && item.authorHandle == handle
            }
        )

        let doomed = try context.fetch(descriptor)
        for item in doomed {
            context.delete(item)
        }
        return doomed.count
    }

    /// A handle in the form rows store it: no leading `@`.
    ///
    /// Mastodon writes `acct` without one and the app stores it verbatim, but a handle reaches this
    /// from a menu title as well as from a row, and that route has an `@` on the front.
    ///
    /// Deliberately **not** case-folded, which looks like the careful thing to do and is not. The
    /// comparison below runs inside a `#Predicate` against the stored column, so folding one side
    /// and not the other is how a mute matches nothing at all. The handle a caller passes comes off
    /// the same `acct` the rows were written from, so an exact match is the one that cannot miss —
    /// and the caller that matters most takes it straight from the row being muted.
    public static func normalised(_ handle: String) -> String {
        var handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        while handle.hasPrefix("@") { handle.removeFirst() }
        return handle
    }
}
