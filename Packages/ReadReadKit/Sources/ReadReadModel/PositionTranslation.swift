import Foundation
import SwiftData

/// Makes a reading position written on one device mean the same thing on another.
///
/// ## The bug this exists for
///
/// A ``SortKey`` is a timestamp plus the item's id, and the id is only there to break ties between
/// items published in the same millisecond. The timestamp is a *server* value, so it is identical
/// everywhere — but the id is not: an item is stored as `freshrss:<account UUID>:<hex>`, and each
/// device generates its own UUID when the account is added. The same article therefore has a
/// different sort key on each device, differing only in the part that decides ties.
///
/// The position is compared with `>`, so that difference lands exactly on the boundary item — the
/// one the marker names. Whether it falls above or below the marker comes down to how the two
/// devices' account UUIDs happen to compare as strings, and for a given pair of devices that answer
/// never changes. When the *writing* device's UUID sorts below the reading device's, the local key
/// for the marked article sorts above the mark, so the article counts as newer than itself: the list
/// opens one item too far down and the item the reader actually stopped on is left counting as new.
/// Either right every time or wrong every time, and wrong by precisely one item.
///
/// ## What this does about it
///
/// Translates a foreign mark into the local key space by finding the *same article* in this store —
/// same millisecond, same provider-side id — and using its local key. Nothing is guessed: when the
/// article cannot be found the mark is returned untouched, which is what every earlier version did
/// with every mark.
///
/// ## What it is not
///
/// A workaround, and the root fix is elsewhere: account ids should be derived from the server and
/// username so that every device names the same account — and therefore the same item — the same
/// way. That also fixes per-feed and Mastodon-Home positions, whose scope ids embed the same UUID
/// and so do not sync across devices at all. This translation is the part that can be done without
/// rewriting every stored id, and it stays useful afterwards for marks written before the change.
public extension ThresholdService {

    /// A mark in this store's own key space.
    ///
    /// - Returns: The local key for the article the mark names, or the mark unchanged when this
    ///   store already agrees with it or cannot place it.
    static func localisedMark(_ mark: SortKey, in context: ModelContext) throws -> SortKey {
        // Sentinels carry no item, and `.distantPast` in particular is the common case for a scope
        // nobody has read.
        guard let markID = mark.id, !markID.isEmpty else { return mark }

        let raw = mark.rawValue

        // The mark already names an item in this store, which is true of every mark this device
        // wrote itself — the overwhelmingly common case, and one COUNT away.
        //
        // Affordable on this path because `CachedItem` carries a plain index on `sortKeyRaw`
        // (see its `#Index`), so this is a seek rather than a scan. Every sidebar count comes
        // through here on every save, and without that index this would be a table scan per scope.
        let exact = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.sortKeyRaw == raw })
        guard try context.fetchCount(exact) == 0 else { return mark }

        guard let stable = stableItemKey(in: markID) else { return mark }

        // Only items sharing the mark's millisecond can be the article it names, since the
        // timestamp comes from the server and does not vary by device. Bounded as a range rather
        // than a prefix match so it uses the same ordering SQLite indexes the column by: the
        // millisecond field is fixed-width, and `}` is the next character above the `|` separator.
        let digits = String(raw.prefix(SortKey.millisDigits))
        let lower = digits + String(SortKey.separator)
        let upper = digits + "}"

        let siblings = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.sortKeyRaw >= lower && $0.sortKeyRaw < upper },
            // Ascending, so a tie between two accounts holding the same article resolves to the
            // lower key. That errs towards counting an item as new rather than as read, which is
            // the direction a reader can recover from.
            sortBy: [SortDescriptor(\.sortKeyRaw)]
        )

        let suffix = String(SourceIdentifier.separator) + stable
        for item in try context.fetch(siblings) where item.id.hasSuffix(suffix) {
            return item.sortKey
        }

        return mark
    }

    /// The part of an item id every device agrees on: what follows `<kind>:<account UUID>:`.
    ///
    /// Split at most twice, so a provider id containing colons of its own survives intact.
    static func stableItemKey(in itemID: String) -> String? {
        let parts = itemID.split(
            separator: SourceIdentifier.separator,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3, !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }
}
