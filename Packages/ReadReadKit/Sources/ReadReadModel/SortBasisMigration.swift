import Foundation
import SwiftData

/// Re-keys a store written when the timeline sorted by the feed's published date.
///
/// Ordering moved onto the server's fetch time — see `CachedItem.sortKeyRaw` — and that is not a
/// change a new build can simply start doing. Every `sortKeyRaw` already in the store is in the old
/// basis, and so is every `PositionMark`: leaving them would mix two orderings in one list and
/// leave the marker pointing at a place that no longer exists.
///
/// Three things have to move together, and the order matters:
///
/// 1. **Which item each marker sits on** is captured *before* anything is rewritten, because it can
///    only be read in the basis it was written in.
/// 2. **The items** are re-keyed.
/// 3. **The markers** are rewritten to the new key of the same item — so the reader keeps their
///    place rather than being dumped at one end of the timeline.
///
/// Idempotent, and guarded by a stored basis number so the pass does not walk every row on every
/// launch.
public enum SortBasisMigration {

    /// Bumped whenever the meaning of `CachedItem.sortKeyRaw` changes.
    ///
    /// `1` is published-date ordering, `2` is fetch-time ordering. A store with no recorded basis
    /// is treated as `1`, which is right for every store written before this existed.
    public static let currentBasis = 2

    private static let defaultsKey = "com.kittmedia.ReadRead.sortKeyBasis"

    /// What one migration pass changed.
    public struct Report: Sendable, Equatable {
        public var itemsRekeyed: Int = 0
        public var marksMoved: Int = 0
        public var lateFlagsCleared: Int = 0
        public var savedEntriesRekeyed: Int = 0

        public var didRun: Bool {
            itemsRekeyed > 0 || marksMoved > 0 || lateFlagsCleared > 0 || savedEntriesRekeyed > 0
        }
    }

    /// Runs the migration if this store has not had it.
    ///
    /// - Parameter deviceID: Whose markers to rewrite. Only this device's rows are touched, because
    ///   only this device may write them — another device's row is in a basis that device still
    ///   has to migrate for itself, and overwriting it here would hand it a key it cannot place.
    ///   Setting this device's row bumps its `updatedAt`, so it wins the reduction meanwhile.
    @discardableResult
    public static func runIfNeeded(
        deviceID: String,
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Report {
        let stored = defaults.object(forKey: defaultsKey) as? Int ?? 1
        guard stored < currentBasis else { return Report() }

        let report = try run(deviceID: deviceID, in: context)
        defaults.set(currentBasis, forKey: defaultsKey)
        return report
    }

    /// The pass itself, without the guard. Exposed for tests.
    @discardableResult
    public static func run(deviceID: String, in context: ModelContext) throws -> Report {
        var report = Report()

        // 1. Read the old basis while it is still the basis.
        let folds = try foldItemIDs(in: context)

        // 2. Re-key. `ingestKeyRaw` is already the exact key wanted, built from the same item id,
        //    so there is nothing to recompute — only to copy.
        let items = try context.fetch(FetchDescriptor<CachedItem>())
        var newKeys: [String: String] = [:]
        for item in items {
            newKeys[item.id] = item.ingestKeyRaw
            if item.sortKeyRaw != item.ingestKeyRaw {
                item.sortKeyRaw = item.ingestKeyRaw
                report.itemsRekeyed += 1
            }
            // Every flag was decided by comparing an old-basis key against an old-basis marker,
            // so none of them means anything now — they are invalid rather than merely stale. In
            // this store that was five and a half thousand rows, each one of which retention had
            // to leave alone while the flag stood.
            if item.arrivedLate {
                item.arrivedLate = false
                report.lateFlagsCleared += 1
            }
        }

        // Read Later keeps a snapshot of the item's key so the list still sorts after the item is
        // pruned. Entries whose item survives are refreshed; the rest keep what they have, which
        // is the best available and still a real timestamp.
        for entry in try context.fetch(FetchDescriptor<ReadLaterEntry>()) {
            guard let key = newKeys[entry.itemID], entry.sortKeyRaw != key else { continue }
            entry.sortKeyRaw = key
            report.savedEntriesRekeyed += 1
        }

        // 3. Put every marker back on the item it was on.
        for fold in folds {
            let target: SortKey
            if let itemID = fold.itemID, let key = newKeys[itemID] {
                target = SortKey(rawValue: key)
            } else if case .readLater = fold.scope, let itemID = fold.itemID,
                      let entry = try ReadLaterService.entry(for: itemID, in: context) {
                // A saved item whose `CachedItem` has already been pruned keeps the key its
                // snapshot carries, which is the only one there is.
                target = entry.sortKey
            } else {
                // No fold item means the marker sat below the oldest item in the scope — the
                // reader is behind everything. `distantPast` is that same place in any basis.
                target = .distantPast
            }
            try ThresholdService.setPosition(
                fold.scope,
                to: target,
                deviceID: deviceID,
                // The timestamp of the row this place was read from, never now.
                //
                // Stamping now was deliberate once — the comment said so: "Setting this device's
                // row bumps its `updatedAt`, so it wins the reduction meanwhile." But this runs at
                // launch, *before* the pull, and winning is precisely what it must not do. A
                // device that has been shut for a week would re-date its week-old place as the
                // freshest in the system, and the position waiting on the server — written
                // yesterday, on the device actually being read — would lose to it.
                //
                // Carrying the derived timestamp says what is true: this is the same position it
                // always was, expressed in the new basis. The same rule `reconcileScopeContainment`
                // follows, for the same reason.
                //
                // Nothing is lost by not winning. Only this device's own rows are re-keyed here,
                // and a foreign row that outranks one of them outranks the old-basis row it
                // replaced too — so the reader ends up at the newest position either way.
                updatedAt: fold.updatedAt,
                in: context
            )
            report.marksMoved += 1
        }

        if report.didRun {
            try context.save()
        }
        return report
    }

    /// Where each positioned scope's marker sits, and how old that answer is.
    private struct Fold {
        var scope: ScopeID
        var itemID: String?
        /// The `updatedAt` of the row this place was reduced from, carried so the rewritten row
        /// can keep it rather than claiming to be new.
        var updatedAt: Date
    }

    /// The item each positioned scope's marker currently sits on.
    ///
    /// Keyed by scope across *all* devices' rows, because the effective position is a reduction
    /// over them: the fold the reader is looking at may be one another device wrote, and that is
    /// the one to preserve.
    private static func foldItemIDs(in context: ModelContext) throws -> [Fold] {
        let marks = try context.fetch(FetchDescriptor<PositionMark>())
        var scopes: [ScopeID] = []
        var seen: Set<String> = []
        for mark in marks where !seen.contains(mark.scopeRaw) {
            seen.insert(mark.scopeRaw)
            scopes.append(mark.scope)
        }

        return try scopes.map { scope in
            // The winning row's own date, from the same reduction the item below is read through,
            // so the two answers cannot come from different rows.
            let updatedAt = try ThresholdService.effectivePosition(for: scope, in: context).updatedAt

            // Read Later orders `ReadLaterEntry`, not `CachedItem`, so it needs its own lookup —
            // and it very much needs one. Re-keying the entries while leaving this marker where it
            // was moves every saved item relative to it: the badge read `0` over a list with an
            // item still in it, which is a saved item the app had stopped mentioning.
            if case .readLater = scope {
                return Fold(
                    scope: scope,
                    itemID: try savedEntryAtPosition(in: context)?.itemID,
                    updatedAt: updatedAt
                )
            }
            return Fold(
                scope: scope,
                itemID: try ThresholdService.itemAtPosition(for: scope, in: context)?.id,
                updatedAt: updatedAt
            )
        }
    }

    /// The Read Later entry the marker sits on — the newest at or below it.
    ///
    /// Found by offset, exactly as `ThresholdService.itemAtPosition` does it: the list is sorted
    /// newest-first, so the entries above the marker occupy `0..<count` and the one at the marker
    /// is at index `count`.
    private static func savedEntryAtPosition(in context: ModelContext) throws -> ReadLaterEntry? {
        let above = try ThresholdService.newerCount(for: .readLater, in: context)
        var descriptor = FetchDescriptor<ReadLaterEntry>(
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchOffset = above
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
