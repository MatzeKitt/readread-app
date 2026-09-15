import Foundation
import SwiftData

/// The `CachedItem` predicates that define what a scope contains.
///
/// These live together for one reason: the timeline list, the sidebar count and the late-arrival
/// list are three different views of the *same* set of items, and they only agree if they share a
/// definition. When each built its own predicate, adding a term to one — the `isFilteredOut`
/// exclusion is the obvious candidate — silently made the count disagree with the list it was
/// counting, which reads as a sync bug and is very hard to attribute.
///
/// `ScopeQueryTests` pins that agreement: a filtered item must be absent from all three.
///
/// Two exclusions are shared by every predicate here — an item hidden by a filter rule, and an item
/// belonging to a switched-off account. Adding either to the list but not to the counts is the
/// mistake this type exists to make impossible.
public enum ScopeQuery {

    /// Items the timeline shows for a scope.
    ///
    /// Deliberately carries no threshold term. The list shows the whole timeline and the marker is
    /// a *position within* it, not a filter on it — hiding items below the marker is what an
    /// unread-based reader does, and is exactly the behaviour this design replaces.
    /// Written as its own switch rather than derived from ``newerPredicate(for:than:)`` with a
    /// floor of `SortKey.distantPast`. That derivation is tempting and wrong: `distantPast` is the
    /// empty string and the comparison is strict, so an item whose `sortKeyRaw` was somehow left
    /// empty would be excluded from the timeline entirely — vanishing from the app with nothing to
    /// attribute it to. An undated row at the bottom of the list is a far better failure.
    public static func displayPredicate(for scope: ScopeID) -> Predicate<CachedItem> {
        switch scope {
        case .all:
            return #Predicate<CachedItem> { !$0.isFilteredOut && $0.isAccountEnabled }

        case .source(let sourceID):
            return #Predicate<CachedItem> { $0.sourceID == sourceID && !$0.isFilteredOut && $0.isAccountEnabled }

        case .mastodonHome(let accountID):
            return displayPredicate(for: .source(SourceIdentifier.mastodonHome(accountID: accountID)))

        case .folder(let name):
            return #Predicate<CachedItem> { $0.folderName == name && !$0.isFilteredOut && $0.isAccountEnabled }

        case .lateArrivals:
            // Across every scope, because an item is flagged relative to whichever marker it
            // landed under and the user wants one place to find all of them.
            return #Predicate<CachedItem> { $0.arrivedLate && !$0.isFilteredOut && $0.isAccountEnabled }

        case .filtered:
            // The inverse of every other scope's `!$0.isFilteredOut`, which is the entire point of
            // the list: it is the one place hidden items are visible. Across every scope, because
            // a rule can be scoped to a feed and the reader looking for a vanished item does not
            // know which one.
            //
            // `isAccountEnabled` still applies. An account switched off has all of its items
            // withheld everywhere, and showing them here would make disabling an account look like
            // it had filtered its items instead.
            return #Predicate<CachedItem> { $0.isFilteredOut && $0.isAccountEnabled }

        case .readLater:
            // Routed to the Read Later list before reaching here; there is no `CachedItem` form.
            return #Predicate<CachedItem> { _ in false }
        }
    }

    /// Items in a scope sitting above its marker.
    ///
    /// - Returns: `nil` for `.readLater`, which has no `CachedItem` form — its entries are
    ///   `ReadLaterEntry` snapshots so that marking something for later survives cache pruning.
    public static func newerPredicate(for scope: ScopeID, than mark: String) -> Predicate<CachedItem>? {
        switch scope {
        case .all:
            return #Predicate<CachedItem> { $0.sortKeyRaw > mark && !$0.isFilteredOut && $0.isAccountEnabled }

        case .source(let sourceID):
            return #Predicate<CachedItem> {
                $0.sourceID == sourceID && $0.sortKeyRaw > mark && !$0.isFilteredOut && $0.isAccountEnabled
            }

        case .mastodonHome(let accountID):
            // A Mastodon home timeline is stored as an ordinary source, so it reuses that path.
            return newerPredicate(
                for: .source(SourceIdentifier.mastodonHome(accountID: accountID)),
                than: mark
            )

        case .folder(let name):
            // Matches the denormalised `folderName` on the item, so this is one index lookup
            // rather than an `IN (…)` over every source id in the folder.
            return #Predicate<CachedItem> {
                $0.folderName == name && $0.sortKeyRaw > mark && !$0.isFilteredOut && $0.isAccountEnabled
            }

        case .lateArrivals:
            // Older Items carries its own marker, like every other scope.
            //
            // It used to return `nil` here, on the reasoning that everything in the list is
            // already below the marker of the scope it landed in — true, and beside the point. A
            // reader scrolling *this* list is reading these items, and with no position of its own
            // there was nowhere to record that: its badge fell back to a plain count of everything
            // flagged, so scrolling to the top showed zero while the list was open and the full
            // number returned the moment another scope was selected. The number looked like it
            // reset itself.
            //
            // The marker of the scope an item landed in is not a substitute, because it moves for
            // reasons that have nothing to do with this list — reading All Items would silently
            // clear Older Items, or fail to.
            return #Predicate<CachedItem> {
                $0.arrivedLate && $0.sortKeyRaw > mark && !$0.isFilteredOut && $0.isAccountEnabled
            }

        case .filtered:
            // The mark is deliberately ignored: this count is a **total**, not a position count.
            //
            // Unlike Older Items, this list is not read through — so a marker moving down it would
            // mean the badge counted "hidden items you have not looked at yet", which is not a
            // question anybody asks. What the badge answers, when it is switched on at all, is how
            // much the rules are currently hiding. `newerCount(for: .filtered)` therefore returns
            // the size of the list, which is what the sidebar shows beside it.
            return #Predicate<CachedItem> { $0.isFilteredOut && $0.isAccountEnabled }

        case .readLater:
            return nil
        }
    }

    /// Items in a scope that arrived carrying a published date below the marker.
    ///
    /// Public because the "older items arrived" list is a `@Query`, and a `@Query` predicate is
    /// built in a view's initialiser where there is no context to consult.
    public static func lateArrivalPredicate(for scope: ScopeID) -> Predicate<CachedItem>? {
        switch scope {
        case .all:
            return #Predicate<CachedItem> { $0.arrivedLate && !$0.isFilteredOut && $0.isAccountEnabled }

        case .source(let sourceID):
            return #Predicate<CachedItem> {
                $0.sourceID == sourceID && $0.arrivedLate && !$0.isFilteredOut && $0.isAccountEnabled
            }

        case .mastodonHome(let accountID):
            return lateArrivalPredicate(
                for: .source(SourceIdentifier.mastodonHome(accountID: accountID))
            )

        case .folder(let name):
            return #Predicate<CachedItem> {
                $0.folderName == name && $0.arrivedLate && !$0.isFilteredOut && $0.isAccountEnabled
            }

        case .lateArrivals:
            return #Predicate<CachedItem> { $0.arrivedLate && !$0.isFilteredOut && $0.isAccountEnabled }

        case .filtered:
            // A hidden item is not offered as a late arrival: it is not in the timeline to have
            // arrived under a marker, and the "older items arrived" notice would be pointing at
            // something the reader cannot see.
            return nil

        case .readLater:
            return nil
        }
    }

    /// Items in a scope strictly above or below a sort key.
    ///
    /// Used to find the item next to another one. Written here, as another exhaustive switch,
    /// rather than by narrowing ``displayPredicate(for:)`` at the call site — `Predicate` does not
    /// compose, and the obvious workaround (replace the predicate with a bound-only one) silently
    /// drops the scope, so swiping through a folder would wander into other folders.
    public static func adjacentPredicate(
        for scope: ScopeID,
        bound: String,
        isNewer: Bool
    ) -> Predicate<CachedItem>? {
        switch scope {
        case .all:
            return isNewer
                ? #Predicate<CachedItem> { $0.sortKeyRaw > bound && !$0.isFilteredOut && $0.isAccountEnabled }
                : #Predicate<CachedItem> { $0.sortKeyRaw < bound && !$0.isFilteredOut && $0.isAccountEnabled }

        case .source(let sourceID):
            return isNewer
                ? #Predicate<CachedItem> {
                    $0.sourceID == sourceID && $0.sortKeyRaw > bound && !$0.isFilteredOut && $0.isAccountEnabled
                }
                : #Predicate<CachedItem> {
                    $0.sourceID == sourceID && $0.sortKeyRaw < bound && !$0.isFilteredOut && $0.isAccountEnabled
                }

        case .mastodonHome(let accountID):
            return adjacentPredicate(
                for: .source(SourceIdentifier.mastodonHome(accountID: accountID)),
                bound: bound,
                isNewer: isNewer
            )

        case .folder(let name):
            return isNewer
                ? #Predicate<CachedItem> {
                    $0.folderName == name && $0.sortKeyRaw > bound && !$0.isFilteredOut && $0.isAccountEnabled
                }
                : #Predicate<CachedItem> {
                    $0.folderName == name && $0.sortKeyRaw < bound && !$0.isFilteredOut && $0.isAccountEnabled
                }

        case .lateArrivals:
            return isNewer
                ? #Predicate<CachedItem> {
                    $0.arrivedLate && $0.sortKeyRaw > bound && !$0.isFilteredOut && $0.isAccountEnabled
                }
                : #Predicate<CachedItem> {
                    $0.arrivedLate && $0.sortKeyRaw < bound && !$0.isFilteredOut && $0.isAccountEnabled
                }

        case .filtered:
            // Provided rather than left `nil` so that reading a hidden item and swiping on can
            // walk the filtered list, instead of walking out of it into the timeline.
            return isNewer
                ? #Predicate<CachedItem> {
                    $0.isFilteredOut && $0.sortKeyRaw > bound && $0.isAccountEnabled
                }
                : #Predicate<CachedItem> {
                    $0.isFilteredOut && $0.sortKeyRaw < bound && $0.isAccountEnabled
                }

        case .readLater:
            return nil
        }
    }
}
