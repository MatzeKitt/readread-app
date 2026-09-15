import Foundation
import SwiftData

/// How much of the item cache to keep.
public struct RetentionPolicy: Sendable, Equatable {

    /// Items kept per source regardless of age.
    ///
    /// Per source rather than overall: a river of a hundred feeds would otherwise let the busiest
    /// two evict everything else, and a quiet monthly newsletter would vanish from a store that is
    /// mostly somebody's link blog.
    public var itemsPerSource: Int

    /// How long an item is kept after it *arrived*.
    public var maximumAge: TimeInterval

    /// The fetch window, in days, or ``HistoryWindow/unlimited`` for none.
    ///
    /// Items published before this are no longer fetched, so keeping them means the store only
    /// ever grows: a week's window against a year of history leaves fifty-one weeks of items that
    /// nothing will ever refresh, reconcile or replace. Bounding the cache by the same number that
    /// bounds the fetch is what makes the store a rolling window rather than an archive.
    ///
    /// Measured on the **published** date, deliberately unlike ``maximumAge``, because that is
    /// what the fetch bound itself is measured on — FreshRSS is sent this as `ot`. Any other
    /// measure would delete items the next run would fetch again, or keep items it never will.
    ///
    /// This is why it does not simply lower ``maximumAge``: the two rules protect different
    /// things and have to coexist. See ``RetentionService/prune(accountIDs:policy:now:)``.
    public var historyWindowDays: Int

    public init(
        itemsPerSource: Int = 1000,
        maximumAge: TimeInterval = 60 * 24 * 60 * 60,
        historyWindowDays: Int = HistoryWindow.unlimited
    ) {
        self.itemsPerSource = itemsPerSource
        self.maximumAge = maximumAge
        self.historyWindowDays = historyWindowDays
    }

    public static let `default` = RetentionPolicy()
}

/// What one pruning pass removed.
public struct RetentionReport: Sendable, Equatable {

    public var itemsDeleted: Int
    public var sourcesConsidered: Int

    public init(itemsDeleted: Int = 0, sourcesConsidered: Int = 0) {
        self.itemsDeleted = itemsDeleted
        self.sourcesConsidered = sourcesConsidered
    }
}

/// Prunes the item cache.
///
/// The cache is disposable — everything in it can be fetched again — so the only question is what
/// must survive. Three of those are promises to the reader and hold under **every** rule below:
///
/// - **Anything above a reading position.** Deleting an item the user has not passed yet makes a
///   sidebar count drop on its own, which reads as items being silently marked read. Checked
///   against every scope that counts the item, not just its own feed: an item can sit below its
///   feed's marker and above the All Items one.
/// - **Anything saved for later.** `ReadLaterEntry` carries its own snapshot, so the saved item
///   would still open — but the timeline row behind it would disappear, and the plan is explicit
///   that saving something is a promise.
/// - **Anything that arrived late and is still waiting.** A late arrival is *by definition*
///   published below the marker of the scope it landed in, so the ordinary position guarantee
///   does not cover it; it is measured against the `.lateArrivals` position instead. Bounded that
///   way rather than exempting the flag outright, because the flag would then be a permanent
///   opt-out of retention — a real store carrying five and a half thousand stale flags from an
///   earlier build could never prune anything at all.
///
/// Two rules then decide what may go, and they are separate because they answer different
/// questions.
///
/// **Age since arrival** is about disk: an item nobody came back to in sixty days is not going to
/// be. Measured on ``CachedItem/ingestKeyRaw`` rather than on publication date, which is the
/// load-bearing part — a feed backfilling a 2019 archive publishes items that are years old the
/// moment they arrive, and ageing by published date would delete them on sight. It also keeps
/// **the newest N of every source**, so a feed read to the end does not empty out.
///
/// **The fetch window** is about coherence: with `Fetch items from` set to a week, items published
/// longer ago are no longer fetched at all, so keeping them leaves a timeline of history that no
/// refresh will ever revisit, reconcile or replace — the store becomes an archive by accident and
/// only ever grows. Measured on `sortKeyRaw`, the published date, because that is what the window
/// bounds: FreshRSS is sent the same instant as `ot`. Any other measure would delete items the
/// next run fetches straight back, or keep items it never will.
///
/// The window rule deliberately ignores the per-source count floor, and that is the whole reason
/// it had to be a second rule rather than a smaller ``RetentionPolicy/maximumAge``. That floor is
/// what stopped a real store — five thousand items across forty-five feeds — from ever pruning
/// anything: at a thousand kept per source, no item was ever both old enough and numerous enough
/// to qualify.
///
/// A `@ModelActor` so a pass over the whole store never touches the main context.
@ModelActor
public actor RetentionService {

    /// Prunes the sources belonging to the given accounts.
    ///
    /// - Parameter accountIDs: Accounts whose ingest run **completed**. Scoped rather than global
    ///   because an interrupted walk has not yet re-fetched what it was going to: pruning on the
    ///   back of one would evict items the very next run intended to restore, and then evict them
    ///   again next time. Empty means nothing is pruned.
    @discardableResult
    public func prune(
        accountIDs: [UUID],
        policy: RetentionPolicy = .default,
        now: Date = .now
    ) throws -> RetentionReport {
        let windowCutoff = HistoryWindow.cutoff(forDays: policy.historyWindowDays, now: now)
            .map { SortKey(date: $0, id: "").rawValue }
        guard !policy.hasNothingToDo(accountIDs, hasWindow: windowCutoff != nil) else {
            return RetentionReport()
        }

        let ageCutoff = SortKey(date: now.addingTimeInterval(-policy.maximumAge), id: "").rawValue
        let saved = try savedItemIDs()

        // Where the reader has got to in Older Items. A late arrival is protected while it sits
        // above this and no longer once it does not — the same promise every other scope gets,
        // rather than a blanket exemption on the flag.
        //
        // The blanket version was wrong in a way only a real store showed: a build that flagged
        // items too eagerly left five and a half thousand rows marked late, and one stale flag
        // then pinned a row forever. Exempting `arrivedLate` outright makes the flag a permanent
        // opt-out of retention, which is not what it is for. `distantPast` — nobody has opened
        // the list — protects all of them, which is the safe end of the range.
        let lateArrivalMark = try ThresholdService
            .effectivePosition(for: .lateArrivals, in: modelContext)
            .markSortKey
            .rawValue

        var report = RetentionReport()

        for source in try sources(for: accountIDs) {
            report.sourcesConsidered += 1

            // The lowest marker that could still count this source's items. Shared by both rules,
            // and fetched once: it costs three position lookups per source.
            let positionFloor = try lowestRelevantMark(for: source)
            let sourceID = source.id

            if policy.maximumAge > 0, let floor = try pruneFloor(
                for: source,
                policy: policy,
                positionFloor: positionFloor
            ) {
                report.itemsDeleted += try delete(#Predicate<CachedItem> { item in
                    item.sourceID == sourceID
                        && item.ingestKeyRaw < ageCutoff
                        && item.sortKeyRaw < floor
                        && !saved.contains(item.id)
                })
            }

            if let windowCutoff {
                report.itemsDeleted += try delete(#Predicate<CachedItem> { item in
                    item.sourceID == sourceID
                        && item.sortKeyRaw < windowCutoff
                        && item.sortKeyRaw < positionFloor
                        && (!item.arrivedLate || item.sortKeyRaw < lateArrivalMark)
                        && !saved.contains(item.id)
                })
            }
        }

        if report.itemsDeleted > 0 {
            try modelContext.save()
        }
        return report
    }

    /// Deletes everything matching, reporting how much that was.
    ///
    /// Counted before deleting because `delete(model:where:)` is a batch delete and reports
    /// nothing, and a retention pass that cannot say what it removed is impossible to trust after
    /// the fact.
    private func delete(_ predicate: Predicate<CachedItem>) throws -> Int {
        let doomed = try modelContext.fetchCount(FetchDescriptor<CachedItem>(predicate: predicate))
        guard doomed > 0 else { return 0 }
        try modelContext.delete(model: CachedItem.self, where: predicate)
        return doomed
    }

    // MARK: - Private

    private func sources(for accountIDs: [UUID]) throws -> [CachedSource] {
        try modelContext.fetch(
            FetchDescriptor<CachedSource>(predicate: #Predicate { accountIDs.contains($0.accountID) })
        )
    }

    /// Item ids that are saved for later, and so are never pruned.
    private func savedItemIDs() throws -> [String] {
        var descriptor = FetchDescriptor<ReadLaterEntry>()
        descriptor.propertiesToFetch = [\.itemID]
        return try modelContext.fetch(descriptor).map(\.itemID)
    }

    /// The sort key below which this source's items may be pruned, or `nil` when none may be.
    ///
    /// The lower of two floors: the Nth-newest item, and the lowest reading position that could
    /// still count this source's items. Whichever is lower wins, because both are promises.
    private func pruneFloor(
        for source: CachedSource,
        policy: RetentionPolicy,
        positionFloor: String
    ) throws -> String? {
        let countFloor: String

        if policy.itemsPerSource <= 0 {
            // Keeping none by count: age and position are the only things holding items back.
            countFloor = SortKey.distantFuture.rawValue
        } else if let key = try nthNewestSortKey(in: source, offset: policy.itemsPerSource - 1) {
            // The *last kept* item's key, not the first dropped one. Offsetting by the policy
            // instead keeps N + 1 items, which is the kind of off-by-one that never shows up until
            // someone counts.
            countFloor = key
        } else {
            // Fewer items than the policy keeps, so there is nothing to consider.
            return nil
        }

        return min(countFloor, positionFloor)
    }

    /// The sort key of the last item inside the keep-window, or `nil` when the source has fewer.
    private func nthNewestSortKey(in source: CachedSource, offset: Int) throws -> String? {
        let sourceID = source.id
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: #Predicate { $0.sourceID == sourceID },
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.sortKeyRaw]
        return try modelContext.fetch(descriptor).first?.sortKeyRaw
    }

    /// The lowest marker any scope containing this source reads behind.
    ///
    /// An item is above the fold if it is above *any* of them, so the lowest is the one that
    /// decides. Getting this wrong is invisible until a count moves on its own.
    private func lowestRelevantMark(for source: CachedSource) throws -> String {
        var scopes: [ScopeID] = [.all, source.scope]
        if let folder = source.folderName {
            scopes.append(.folder(folder))
        }

        var lowest = SortKey.distantFuture
        for scope in scopes {
            let mark = try ThresholdService.effectivePosition(for: scope, in: modelContext).markSortKey
            lowest = min(lowest, mark)
        }
        return lowest.rawValue
    }
}

private extension RetentionPolicy {
    /// Whether neither rule can delete anything, so the pass can return without touching the store.
    ///
    /// `maximumAge <= 0` switches the age rule off rather than the whole pass — with a fetch
    /// window set there is still work to do.
    func hasNothingToDo(_ accountIDs: [UUID], hasWindow: Bool) -> Bool {
        accountIDs.isEmpty || itemsPerSource < 0 || (maximumAge <= 0 && !hasWindow)
    }
}
