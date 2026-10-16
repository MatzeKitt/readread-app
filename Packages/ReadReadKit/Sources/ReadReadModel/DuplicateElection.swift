import Foundation
import SwiftData

/// Picks the one copy of a post the merged lists show, when several accounts have fetched it.
///
/// Follow someone from two accounts and each home timeline stores their posts under its own id,
/// which is right: each account's timeline is complete, and liking or replying acts as the account
/// whose copy it is. What is wrong is All Items showing every post twice. So every copy but one is
/// flagged ``CachedItem/isDuplicate``, and the scopes that merge accounts leave the flagged ones
/// out — see ``ScopeQuery``.
///
/// A stored flag rather than something worked out per query, for the reason `isFilteredOut` is
/// one: "the first row of each group" is not something a `#Predicate` can say, and the list and
/// every count have to agree on it.
///
/// ## Which copy wins
///
/// Decided by the rows alone, so that every device makes the same choice with no handshake —
/// a reading position names a row, and two devices that kept different copies would be pointing
/// at different ones.
///
/// 1. A copy the merged lists would show at all: its account switched on and no rule hiding it.
///    Otherwise a rule on one account's timeline, or one account being switched off, would take
///    the post out of All Items even though another account still has it in plain view.
/// 2. Then a copy that is only filtered, over one from a switched-off account, so Filtered Items
///    lists a post hidden everywhere exactly once.
/// 3. Then the **oldest** copy. A boost of a post brings it back with a later time, and promoting
///    that copy would lift a post the reader has already scrolled past back above their position,
///    to be read again. The oldest is where they first met it.
/// 4. Then the row id, so two copies with the same time still have one answer.
///
/// Rewritten whenever the copies or their visibility change — at ingest, after a filter pass, when
/// an account is switched or removed, after pruning — because a flag left behind by a copy that has
/// gone would hide the post from All Items altogether. The launch pass re-elects everything, which
/// is what makes a missed occasion heal rather than stick.
public enum DuplicateElection {

    /// How many keys go into one `IN (…)`. Well below SQLite's limit on bound variables, and a
    /// page of a timeline is far below it.
    private static let keysPerFetch = 500

    /// Re-elects the copies of the given posts.
    ///
    /// For callers that know which posts they touched: an ingest page, an account's items, a mute.
    /// Rows the context has inserted or deleted but not yet saved count as they will once it saves.
    ///
    /// Does not save.
    ///
    /// - Returns: How many rows changed.
    @discardableResult
    public static func reelect(keys: some Sequence<String>, in context: ModelContext) throws -> Int {
        let wanted = Array(Set(keys.filter { !$0.isEmpty }))
        var changed = 0
        var start = 0
        while start < wanted.count {
            // Optional, because the column is: comparing against plain strings does not type-check,
            // and coalescing the column to one inside the predicate is the form the store throws on
            // at fetch time.
            let chunk: [String?] = wanted[start..<min(start + keysPerFetch, wanted.count)].map { $0 }
            var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { chunk.contains($0.duplicateKey) })
            descriptor.propertiesToFetch = fetchedProperties
            changed += apply(try context.fetch(descriptor))
            start += keysPerFetch
        }
        return changed
    }

    /// Re-elects every post that has a key.
    ///
    /// For the occasions that can change any group — a filter pass, an account removed, pruning —
    /// and at launch. A narrow fetch of the statuses alone, so it is a column scan rather than a
    /// pass over every article body.
    ///
    /// Does not save.
    ///
    /// - Returns: How many rows changed.
    @discardableResult
    public static func reelectAll(in context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.duplicateKey != nil })
        descriptor.propertiesToFetch = fetchedProperties
        return apply(try context.fetch(descriptor))
    }

    /// The columns an election reads and writes, so the bodies stay on disk. Computed, because key
    /// paths are not `Sendable` and a stored static would be shared state.
    private static var fetchedProperties: [PartialKeyPath<CachedItem>] {
        [
            \.id, \.duplicateKey, \.sortKeyRaw, \.isAccountEnabled, \.isFilteredOut, \.isDuplicate,
        ]
    }

    /// Flags all but the winner of each group, and clears the flag everywhere else.
    ///
    /// Writes only rows whose flag actually changes, so a pass that finds everything already right
    /// leaves the context clean and the timeline's queries undisturbed.
    private static func apply(_ rows: [CachedItem]) -> Int {
        var groups: [String: [CachedItem]] = [:]
        for row in rows {
            // An empty key is a payload that would not decode: no identity, so it stands alone.
            guard let key = row.duplicateKey, !key.isEmpty else {
                if row.isDuplicate { row.isDuplicate = false }
                continue
            }
            groups[key, default: []].append(row)
        }

        var changed = 0
        for copies in groups.values {
            let winner = copies.min { rank($0) < rank($1) }
            for copy in copies {
                let isDuplicate = copy !== winner
                guard copy.isDuplicate != isDuplicate else { continue }
                copy.isDuplicate = isDuplicate
                changed += 1
            }
        }
        return changed
    }

    /// Lower wins. See the type's documentation for the order and the reasons for it.
    private static func rank(_ row: CachedItem) -> (Int, String, String) {
        let visibility = !row.isAccountEnabled ? 2 : (row.isFilteredOut ? 1 : 0)
        return (visibility, row.sortKeyRaw, row.id)
    }
}
