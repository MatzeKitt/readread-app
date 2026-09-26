import Foundation
import SwiftData

/// Reads and moves reading positions, and counts what sits above them.
///
/// A namespace of functions over a `ModelContext` rather than a stored object: SwiftData contexts
/// are not `Sendable` and are bound to the actor that made them, so holding one inside a service
/// would fix the whole threshold layer to a single actor. Passing the context in lets the same code
/// run on the main context for UI reads and on a background context during ingest.
public enum ThresholdService {

    // MARK: - Reading positions

    /// The position for a scope, reduced across every device's row and translated into this store's
    /// own key space.
    ///
    /// The translation is what makes a synced position land on the right item — see
    /// ``localisedMark(_:in:)``. Done here rather than at each caller because every count, every
    /// badge and the restore itself all go through this one function, and a position that means
    /// something slightly different depending on which of them asked would be worse than the bug.
    public static func effectivePosition(for scope: ScopeID, in context: ModelContext) throws -> EffectivePosition {
        let scopeRaw = scope.rawValue
        let marks = try context.fetch(
            FetchDescriptor<PositionMark>(predicate: #Predicate { $0.scopeRaw == scopeRaw })
        )
        var position = EffectivePosition.reduce(
            marks.map { (deviceID: $0.deviceID, markSortKey: $0.markSortKey, updatedAt: $0.updatedAt) },
            scope: scope
        )
        position.markSortKey = try localisedMark(position.markSortKey, in: context)
        return position
    }

    /// Moves this device's position to `target`.
    ///
    /// Free to move in either direction, because a position is a place rather than a claim about
    /// what has been read: scrolling down puts items back above the fold and the count must rise
    /// to say so. An earlier version was forward-only, with a `reset` that bumped a generation
    /// counter to move backwards; that could not express the count at all, since a reader who had
    /// once reached the top stayed "up to date" no matter where they scrolled afterwards.
    ///
    /// Writes unconditionally, even when the position has not moved, and that matters: the
    /// timestamp is what makes this device authoritative. Skipping the write for an unchanged
    /// position would mean that scrolling *back* to somewhere you had already been left another
    /// device's later row winning the reduction — so your own screen would keep showing that
    /// device's count instead of yours.
    ///
    /// Returns the row it wrote, so the caller can queue it for sync in the same transaction as the
    /// change itself. A local edit and its outbox entry have to be saved together or not at all —
    /// otherwise a crash between the two loses the push and the position never leaves the device.
    /// - Parameter updatedAt: When to date the row. Defaults to now, which is the answer for every
    ///   caller that is recording where the reader *is*. A caller that merely re-expresses a
    ///   position the app already held — a migration re-keying it, a repair deriving one — passes
    ///   the timestamp it derived from instead, so a device that has been away cannot re-date a
    ///   stale place into the freshest one in the system. See ``reconcileScopeContainment(deviceID:in:)``.
    @discardableResult
    public static func setPosition(
        _ scope: ScopeID,
        to target: SortKey,
        deviceID: String,
        updatedAt: Date = .now,
        in context: ModelContext
    ) throws -> PositionMark {
        let mark = try mark(for: scope, deviceID: deviceID, in: context)
        mark.markSortKey = target
        mark.updatedAt = updatedAt
        return mark
    }

    /// Moves this device's position for `scope` and for every scope that overlaps it.
    ///
    /// ## Why one scroll has to touch more than one scope
    ///
    /// Positions used to be wholly independent, one per scope, and the sidebar contradicted itself
    /// as a result. `All Items` *contains* every folder and every feed, so a reader who scrolls
    /// only that timeline moves only that one marker: the folders keep whatever they were seeded
    /// with on first sync and their counts climb forever. `All Items: 9` sitting above `RSS: 46`
    /// is the visible form of it, and no amount of reading `All Items` would ever bring the 46
    /// down — the only way to clear a folder was to open it, which defeats having the count.
    ///
    /// A position is a statement about a *set* of items, so it propagates the way containment
    /// does:
    ///
    /// - The scope being scrolled is set to exactly where the fold is.
    /// - Scopes **inside** it get the same key. Scrolling `All Items` to a point means every
    ///   folder and feed has been carried past that point too, so each one's count becomes exactly
    ///   its share of the total — the sidebar adds up.
    /// - Scopes **containing** it are lowered to that key when they sat above it, and otherwise
    ///   left alone. This is what keeps `child ≤ parent` true when a reader goes *backwards*
    ///   inside a folder: without it, scrolling `RSS` down twenty items would show `RSS: 20` under
    ///   `All Items: 0`.
    ///
    /// Deliberately **not** symmetric: reading a folder does not carry its siblings, so looking
    /// back through one folder cannot resurrect a Mastodon backlog that had already been cleared.
    /// What that asymmetry costs is that a lowered parent can exceed the sum of its visible
    /// children in exactly that case — those items are real and sitting above the parent's fold,
    /// they are just still below their own folder's. Of the three inconsistencies on offer here an
    /// over-counting parent is the mildest; the alternatives are a child larger than its parent,
    /// or collapsing every scope onto a single global position.
    ///
    /// `.readLater`, `.lateArrivals` and `.filtered` propagate nothing. They are cross-cutting
    /// views rather than places in the tree, and their markers move for reasons of their own — or,
    /// for `.filtered`, not at all.
    ///
    /// - Returns: Every row it wrote, so a caller can queue them all for sync in the same
    ///   transaction as the change. See ``setPosition(_:to:deviceID:in:)`` for why each write is
    ///   unconditional.
    @discardableResult
    public static func setPositionCascading(
        _ scope: ScopeID,
        to target: SortKey,
        deviceID: String,
        in context: ModelContext
    ) throws -> [PositionMark] {
        // One fetch of this device's rows, rather than a keyed lookup per scope: a store with
        // forty feeds cascades forty-odd writes per settled scroll, and that many round trips
        // through `mark(for:deviceID:in:)` would be the expensive part of scrolling.
        var rows = try marks(forDeviceID: deviceID, in: context)
        var written: [PositionMark] = []

        func write(_ scope: ScopeID) {
            let row: PositionMark
            if let existing = rows[scope.rawValue] {
                row = existing
            } else {
                row = PositionMark(scope: scope, deviceID: deviceID)
                context.insert(row)
                rows[scope.rawValue] = row
            }
            row.markSortKey = target
            row.updatedAt = .now
            written.append(row)
        }

        write(scope)

        for contained in try containedScopes(of: scope, in: context) where contained != scope {
            write(contained)
        }

        for enclosing in try enclosingScopes(of: scope, in: context) {
            // A scope with no row yet sits at `distantPast`, which is already below any target,
            // so there is nothing to lower.
            guard let row = rows[enclosing.rawValue], row.markSortKey > target else { continue }
            write(enclosing)
        }

        return written
    }

    /// Brings this device's existing marks back inside the containment rule.
    ///
    /// The cascade keeps a parent at or below its children from the moment it runs, but it can
    /// only fix scopes on scrolls that happen *after* it. A store written before it existed holds
    /// exactly the state that made this necessary: `All Items` scrolled repeatedly and sitting
    /// near the top, every folder still on the marker first sync seeded it with. Without a repair
    /// pass the sidebar keeps showing `All Items: 9` above `RSS: 46` until the reader happens to
    /// scroll again — and the count is the thing they were looking at to decide whether to.
    ///
    /// Repairs by **raising** a child to its parent, never by lowering the parent. Raising is the
    /// reading the store already supports: reaching a point in `All Items` means passing that
    /// point in every folder inside it. Lowering `All Items` to the least-read folder would throw
    /// away a position the reader actually established.
    ///
    /// Idempotent, so it can run on every launch rather than being tracked as a migration — which
    /// it has to, since marks also arrive by sync from a device that may still be on an older
    /// build.
    ///
    /// ## Why the repaired rows keep the timestamp they were derived from
    ///
    /// A repair is not a report. The reader did not go anywhere — this pass is restating, for a
    /// child scope, a position its parent already held — so it carries the parent's time rather
    /// than the time of the repair. Stamping `.now` would make it a report, and it would be a
    /// backdated one: ``EffectivePosition/reduce(_:scope:)`` takes the most recently written row,
    /// so a device launching a week behind would derive its folders from its own stale `All Items`
    /// and publish them as the freshest word on where the reader is. Every other device would
    /// then dutifully follow it backwards.
    ///
    /// That is the same trap `SwiftDataIngestSink.seedUnmarkedScopes` is held off the first pull
    /// for, and the same one `PositionPublication` keeps the timeline's restore out of. The rule
    /// behind all three: **only the reader moves a position.** Everything else either derives one,
    /// and inherits its time, or does not write at all.
    ///
    /// - Returns: The rows it changed, for the caller to queue for sync. Empty when nothing
    ///   violated the rule, which is the normal case.
    @discardableResult
    public static func reconcileScopeContainment(
        deviceID: String,
        in context: ModelContext
    ) throws -> [PositionMark] {
        guard !deviceID.isEmpty else { return [] }

        var rows = try marks(forDeviceID: deviceID, in: context)
        let sources = try subscribedSources(in: context)
        var repaired: [PositionMark] = []

        func markSortKey(_ scope: ScopeID) -> SortKey {
            rows[scope.rawValue]?.markSortKey ?? .distantPast
        }

        /// When the scope's position was last reported, so a repair derived from it can say so.
        func reportedAt(_ scope: ScopeID) -> Date {
            rows[scope.rawValue]?.updatedAt ?? .distantPast
        }

        /// - Parameter asOf: When the position being copied down was reported. See the note above.
        func raise(_ scope: ScopeID, toAtLeast floor: SortKey, asOf asOfDate: Date) {
            guard floor > markSortKey(scope) else { return }
            let row: PositionMark
            if let existing = rows[scope.rawValue] {
                row = existing
            } else {
                // A scope with no row at all is the worst case, not an exempt one: it reads as
                // `distantPast` and so counts its entire history.
                row = PositionMark(scope: scope, deviceID: deviceID)
                context.insert(row)
                rows[scope.rawValue] = row
            }
            row.markSortKey = floor
            row.updatedAt = asOfDate
            repaired.append(row)
        }

        let all = markSortKey(.all)
        let allReportedAt = reportedAt(.all)

        // Folders before feeds, so a feed is measured against its folder's repaired position
        // rather than the one it is about to lose.
        for folder in Set(sources.compactMap(\.folderName)).sorted() {
            raise(.folder(folder), toAtLeast: all, asOf: allReportedAt)
        }
        for source in sources {
            // Whichever bound wins brings its own time with it, since that is the report being
            // restated. Taken together rather than as a `max` over keys alone, which would have
            // paired a folder's key with `All Items`' timestamp.
            var floor = all
            var floorReportedAt = allReportedAt
            if let name = source.folderName, markSortKey(.folder(name)) > floor {
                floor = markSortKey(.folder(name))
                floorReportedAt = reportedAt(.folder(name))
            }
            raise(source.scope, toAtLeast: floor, asOf: floorReportedAt)
        }

        return repaired
    }

    // MARK: - Containment

    /// The scopes wholly contained by `scope`.
    ///
    /// Folders are derived from the subscribed sources rather than read from a folder table,
    /// because there is no folder table: a folder exists exactly as long as some source names it.
    ///
    /// Shared with marker seeding so that the set of scopes a cascade reaches and the set that
    /// gets seeded on first sync cannot drift apart. They were written twice once, and the
    /// difference is invisible until a scope that one knows about and the other does not starts
    /// counting its whole backlog.
    public static func containedScopes(of scope: ScopeID, in context: ModelContext) throws -> [ScopeID] {
        switch scope {
        case .all:
            let sources = try subscribedSources(in: context)
            let folders = Set(sources.compactMap(\.folderName)).sorted()
            return sources.map(\.scope) + folders.map(ScopeID.folder)

        case .folder(let name):
            return try subscribedSources(in: context)
                .filter { $0.folderName == name }
                .map(\.scope)

        case .source, .mastodonHome, .lateArrivals, .readLater, .filtered:
            return []
        }
    }

    /// The scopes that wholly contain `scope`, outermost first.
    public static func enclosingScopes(of scope: ScopeID, in context: ModelContext) throws -> [ScopeID] {
        switch scope {
        case .all, .lateArrivals, .readLater, .filtered:
            return []

        case .folder:
            return [.all]

        case .source, .mastodonHome:
            // A feed whose source row is missing is still inside `All Items`, so the fallback is
            // the enclosing scope we are certain of rather than none at all.
            guard
                let sourceID = SourceIdentifier.sourceID(for: scope),
                let folder = try source(withID: sourceID, in: context)?.folderName
            else { return [.all] }
            return [.all, .folder(folder)]
        }
    }

    private static func subscribedSources(in context: ModelContext) throws -> [CachedSource] {
        try context.fetch(FetchDescriptor<CachedSource>(predicate: #Predicate { $0.isSubscribed }))
    }

    private static func source(withID id: String, in context: ModelContext) throws -> CachedSource? {
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Every position row this device owns, keyed by scope.
    private static func marks(
        forDeviceID deviceID: String,
        in context: ModelContext
    ) throws -> [String: PositionMark] {
        let rows = try context.fetch(
            FetchDescriptor<PositionMark>(predicate: #Predicate { $0.deviceID == deviceID })
        )
        return Dictionary(rows.map { ($0.scopeRaw, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// This device's row for a scope, created on first use.
    private static func mark(
        for scope: ScopeID,
        deviceID: String,
        in context: ModelContext
    ) throws -> PositionMark {
        let key = PositionMark.key(scope: scope, deviceID: deviceID)
        var descriptor = FetchDescriptor<PositionMark>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let created = PositionMark(scope: scope, deviceID: deviceID)
        context.insert(created)
        return created
    }

    // MARK: - Counts

    /// How many items in a scope sit above its marker.
    ///
    /// Deliberately a `fetchCount` against an index, not a fetch-then-count: the sidebar asks this
    /// for every folder and feed on every change, and loading rows to count them would make
    /// scrolling stutter on a large store.
    public static func newerCount(for scope: ScopeID, in context: ModelContext) throws -> Int {
        let mark = try effectivePosition(for: scope, in: context).markSortKey.rawValue

        if case .readLater = scope {
            return try context.fetchCount(
                FetchDescriptor<ReadLaterEntry>(predicate: #Predicate { $0.sortKeyRaw > mark })
            )
        }

        guard let predicate = ScopeQuery.newerPredicate(for: scope, than: mark) else { return 0 }
        return try context.fetchCount(FetchDescriptor<CachedItem>(predicate: predicate))
    }

    /// How many items arrived carrying a published date below the marker, and so are sitting
    /// below the threshold where they read as already-seen.
    ///
    /// Surfaced separately by the timeline rather than folded into ``newerCount(for:in:)``, since
    /// counting them would contradict the chronological ordering the list is showing.
    public static func lateArrivalCount(for scope: ScopeID, in context: ModelContext) throws -> Int {
        guard let predicate = ScopeQuery.lateArrivalPredicate(for: scope) else { return 0 }
        return try context.fetchCount(FetchDescriptor<CachedItem>(predicate: predicate))
    }

    // MARK: - Timeline navigation

    /// The newest item in a scope, or `nil` when it holds none.
    public static func newestItem(for scope: ScopeID, in context: ModelContext) throws -> CachedItem? {
        var descriptor = FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: scope),
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The item the reading position sits on — the newest item at or below the marker.
    ///
    /// This is what a scope opens at, and what "Scroll to Timeline Position" returns to. Because
    /// the position records the item at the *fold*, scrolling that same item back to the top
    /// restores the view exactly rather than approximately.
    ///
    /// Found by offset rather than by a fourth `sortKeyRaw <= mark` predicate. The timeline is
    /// sorted newest-first, so the items above the marker occupy exactly indices
    /// `0..<newerCount` — which makes the item at the marker the one at index `newerCount`. One
    /// indexed query, and it reuses the display predicate, so this cannot disagree with the list
    /// the user is looking at.
    public static func itemAtPosition(for scope: ScopeID, in context: ModelContext) throws -> CachedItem? {
        let above = try newerCount(for: scope, in: context)

        var descriptor = FetchDescriptor<CachedItem>(
            predicate: ScopeQuery.displayPredicate(for: scope),
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        )
        descriptor.fetchOffset = above
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Whether this store holds the row a mark names.
    ///
    /// The question ``itemAtPosition(for:in:)`` cannot answer. That one finds the item at the
    /// marker *by offset* — the newest item at or below it — so it returns something for any
    /// non-empty scope, including when the marker is a key from another device's id space that
    /// this store has no way to compare meaningfully. "There is an item there" and "the item the
    /// mark names is here" are different facts, and only this one distinguishes a position that
    /// can be acted on from one whose article has not arrived yet.
    ///
    /// Asked with the mark already localised — see ``localisedMark(_:in:)`` — so a foreign mark
    /// naming an article this store *does* have reads as placeable.
    ///
    /// A `fetchCount` against the `sortKeyRaw` index, so it costs a seek rather than a scan.
    public static func holdsItem(at mark: SortKey, for scope: ScopeID, in context: ModelContext) throws -> Bool {
        let raw = mark.rawValue
        // A sentinel names no item. `.distantPast` in particular is every unread scope's marker,
        // and reading it as "placeable" would make an unread scope look like a report to act on.
        guard !raw.isEmpty, mark != .distantFuture else { return false }

        // Read Later orders its own rows and its entries outlive the items they were taken from,
        // so asking `CachedItem` there would call every saved article unplaceable the moment
        // retention pruned it. Same split as `newerCount(for:in:)`.
        if case .readLater = scope {
            return try context.fetchCount(
                FetchDescriptor<ReadLaterEntry>(predicate: #Predicate { $0.sortKeyRaw == raw })
            ) > 0
        }
        return try context.fetchCount(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.sortKeyRaw == raw })
        ) > 0
    }

    /// Clears the late-arrival flag across a scope, dismissing the "older items arrived" notice.
    ///
    /// - Returns: How many items were cleared.
    @discardableResult
    public static func clearLateArrivals(for scope: ScopeID, in context: ModelContext) throws -> Int {
        guard let predicate = ScopeQuery.lateArrivalPredicate(for: scope) else { return 0 }
        let items = try context.fetch(FetchDescriptor<CachedItem>(predicate: predicate))
        for item in items {
            item.arrivedLate = false
        }
        return items.count
    }

    // MARK: - Denormalisation

    /// Rewrites the denormalised `folderName` on every item of a source.
    ///
    /// Called by subscription sync when a feed moves between FreshRSS categories. Without this the
    /// feed's existing items would stay attached to the old folder's count and timeline, and only
    /// newly-ingested items would appear in the right place — a discrepancy that would look like a
    /// sync bug rather than a stale denormalisation.
    /// Marks every item of an account as belonging to a switched-on or switched-off account.
    ///
    /// A batch rewrite rather than a join, for the same reason `updateFolderName` is one: the flag
    /// has to be on the item for a `@Query` predicate to reach it. Switching an account off is a
    /// deliberate, rare action, so paying a pass over its items once is the right trade against
    /// making every timeline query and every sidebar count consult the account table.
    ///
    /// - Returns: How many items changed, so a caller can skip saving when nothing did.
    @discardableResult
    public static func setAccountEnabled(
        _ isEnabled: Bool,
        forAccountID accountID: UUID,
        in context: ModelContext
    ) throws -> Int {
        let items = try context.fetch(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.accountID == accountID })
        )
        var changed = 0
        for item in items where item.isAccountEnabled != isEnabled {
            item.isAccountEnabled = isEnabled
            changed += 1
        }
        return changed
    }

    /// Brings every item's copy of the flag back in line with its account.
    ///
    /// Exists for the cases the toggle cannot cover: a store written before the flag existed, and
    /// an account switched off on another device and pulled in by sync. Only accounts that are
    /// actually switched off are scanned, so the usual cost is a single account fetch and nothing
    /// else.
    @discardableResult
    public static func reconcileAccountVisibility(in context: ModelContext) throws -> Int {
        var changed = 0
        for account in try context.fetch(FetchDescriptor<AccountRecord>()) {
            changed += try setAccountEnabled(account.isEnabled, forAccountID: account.id, in: context)
        }
        if changed > 0 { try context.save() }
        return changed
    }

    public static func updateFolderName(
        _ folderName: String?,
        forSourceID sourceID: String,
        in context: ModelContext
    ) throws {
        let items = try context.fetch(
            FetchDescriptor<CachedItem>(predicate: #Predicate { $0.sourceID == sourceID })
        )
        for item in items where item.folderName != folderName {
            item.folderName = folderName
        }
    }
}

/// Builds the namespaced ids that tie sources, items and scopes together.
///
/// Centralised because the same string is constructed during FreshRSS ingest, Mastodon ingest and
/// scope resolution, and a mismatch between any two of them would silently split one feed into two
/// — with two reading positions and neither of them right.
public enum SourceIdentifier {

    /// Separates the kind, the account and the provider's own id.
    ///
    /// Named because ``ThresholdService/stableItemKey(in:)`` has to take these ids apart again, and
    /// a second copy of the character would be free to drift from this one.
    public static let separator: Character = ":"

    public static func freshRSS(accountID: UUID, streamID: String) -> String {
        "freshrss:\(accountID.uuidString):\(streamID)"
    }

    public static func mastodonHome(accountID: UUID) -> String {
        "mastodon:\(accountID.uuidString):home"
    }

    public static func freshRSSItem(accountID: UUID, itemID: String) -> String {
        "freshrss:\(accountID.uuidString):\(itemID)"
    }

    public static func mastodonItem(accountID: UUID, statusID: String) -> String {
        "mastodon:\(accountID.uuidString):\(statusID)"
    }

    /// The source id a scope addresses, when it addresses one.
    ///
    /// The inverse of ``CachedSource/scope``, and it has to stay that way: `.mastodonHome` and
    /// `.source` are two scope forms over the same row, so anything mapping between the two has to
    /// agree with the mapping that produced them.
    public static func sourceID(for scope: ScopeID) -> String? {
        switch scope {
        case .source(let id):
            return id
        case .mastodonHome(let accountID):
            return mastodonHome(accountID: accountID)
        case .all, .folder, .readLater, .lateArrivals, .filtered:
            return nil
        }
    }
}
