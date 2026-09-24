import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftData

/// Re-keys a store whose accounts were given random ids.
///
/// ## What was wrong
///
/// `AccountRecord.id` used to be a fresh `UUID()` on whichever device the account was signed in
/// on, and that id is embedded in everything the account produces: `CachedSource.id`,
/// `CachedItem.id`, `ReadLaterEntry.itemID`, the `source:` and `mastodon-home:` scopes, and
/// through the scopes the key of every `PositionMark`. So the same feed, the same article and the
/// same scope were **named differently on each device**, and every synced record that mentioned
/// one pointed at a row the receiving device did not have.
///
/// Three symptoms came out of that one fact, and they were each patched where they showed:
/// per-feed and Mastodon-Home positions that never synced at all, a restored position landing one
/// item off (`ThresholdService.localisedMark`), and Read Later entries opening an empty reading
/// pane (`ItemResolution.cachedItem(for:in:)`). This is the cause rather than a fourth patch:
/// ``AccountIdentity/accountID`` derives the id from the account's kind, server and username, so
/// every device computes the same one, and this pass rewrites what is already stored to match.
///
/// ## Why it is not guarded by a version number
///
/// `SortBasisMigration` has to be, because it walks every item unconditionally. This one begins by
/// comparing a handful of account rows against their derived ids and stops there when they agree,
/// which is the case on every launch after the first. Leaving it unguarded makes it *self-healing*
/// instead: an account that arrives from a device still running an older build brings a random id
/// with it, and the next launch quietly puts it right rather than leaving a store that a version
/// key has already declared migrated.
///
/// ## What it deliberately does not do
///
/// It does not touch position rows belonging to a device whose account ids it cannot recognise —
/// there is nothing to map them to — and it does not delete anything to tidy up after itself
/// beyond the sync records it owns. `AccountDeduplication` still handles duplicate account rows,
/// and the two translation patches stay where they are: marks written before this ran are still
/// out there on the server, and `localisedMark` is what makes them land.
public enum AccountIDMigration {

    /// What one pass changed. Every count is rows actually rewritten, not rows examined.
    public struct Report: Sendable, Equatable {

        /// Old id to derived id, for whatever else in the app has an account id stored in it —
        /// the badge scope in Settings, for one, which no `ModelContext` can reach.
        public var accounts: [UUID: UUID] = [:]

        public var sources = 0
        public var items = 0
        public var readLaterEntries = 0
        public var positionMarks = 0
        public var cursors = 0
        public var filterRules = 0

        /// Rows dropped because the id they should have taken was already in use by a row that had
        /// been migrated, or had arrived, first. Renaming onto an occupied id would violate the
        /// model's uniqueness constraint and fail the whole save.
        public var discardedDuplicates = 0

        public var didRun: Bool { !accounts.isEmpty }
    }

    /// Rewrites every stored id that embeds an account id, and queues the sync records for it.
    ///
    /// Nothing is saved when there is nothing to do, so the ordinary launch cost is one fetch of
    /// the account table.
    ///
    /// - Parameters:
    ///   - deviceID: This device's id, so the pass can tell its own position rows — the ones it
    ///     may push — from rows belonging to other devices, which it rewrites but must not claim.
    ///   - keychain: Injected so a test can watch a credential move without touching the real one.
    /// - Returns: What changed, including the mapping, for callers with ids stored outside the
    ///   store.
    @discardableResult
    public static func run(
        deviceID: String,
        in context: ModelContext,
        keychain: KeychainStore = KeychainStore()
    ) throws -> Report {
        var report = Report()

        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        let mapping = mapping(for: accounts)
        guard !mapping.isEmpty else { return report }

        // Credentials first, and accounts that cannot be moved are dropped from the pass.
        //
        // An account whose row is renamed while its Keychain item is not is an account that is
        // silently signed out: `AccountConnections` looks the credential up by the id on the row.
        // Leaving such an account on its old id costs nothing but the fix being deferred, so a
        // Keychain that refuses is a reason to skip one account rather than to abandon the pass or
        // to break it.
        report.accounts = moveCredentials(for: accounts, using: mapping, keychain: keychain)
        guard !report.accounts.isEmpty else { return report }
        let map = report.accounts

        try rewriteSources(in: context, using: map, into: &report)
        try rewriteItems(in: context, using: map, into: &report)
        try rewriteReadLater(in: context, using: map, into: &report)
        try rewritePositions(deviceID: deviceID, in: context, using: map, into: &report)
        try rewriteCursors(in: context, using: map, into: &report)
        try rewriteFilters(in: context, using: map, into: &report)

        // Last, so everything that reads `accountID` above has been rewritten against the old
        // value it is still holding.
        for account in accounts {
            guard let new = map[account.id] else { continue }
            account.id = new
            // Queued so the derived id reaches the server, which is what lets a device still
            // running an older build converge on it rather than the other way round. The account's
            // *old* record is deliberately left alone: an account tombstone is matched by identity
            // on the receiving side, so deleting it would delete the account everywhere.
            try SyncOutbox.record(account, in: context)
        }

        try context.save()
        return report
    }

    // MARK: - Deciding what to rename

    /// Old id to derived id, for the accounts that need one and can safely take it.
    ///
    /// Two collisions are possible and both are left alone rather than resolved here. Two rows
    /// that derive to the *same* id are two copies of one account, and picking a winner is
    /// `AccountDeduplication`'s job — it knows which copy holds a credential. A row deriving onto
    /// an id another row already carries is the same situation seen from the other end.
    private static func mapping(for accounts: [AccountRecord]) -> [UUID: UUID] {
        let occupied = Set(accounts.map(\.id))
        var derived: [UUID: UUID] = [:]
        var claimed: Set<UUID> = []
        var contested: Set<UUID> = []

        for account in accounts {
            let target = AccountIdentity(account).accountID
            guard target != account.id else { continue }
            if claimed.contains(target) { contested.insert(target) }
            claimed.insert(target)
            derived[account.id] = target
        }

        return derived.filter { _, target in
            !contested.contains(target) && !occupied.contains(target)
        }
    }

    /// Moves each account's secret to its new id, and reports which accounts may now be renamed.
    private static func moveCredentials(
        for accounts: [AccountRecord],
        using mapping: [UUID: UUID],
        keychain: KeychainStore
    ) -> [UUID: UUID] {
        var moved: [UUID: UUID] = [:]

        for account in accounts {
            guard let new = mapping[account.id] else { continue }

            let purpose: KeychainStore.Purpose = switch account.kind {
            case .freshRSS: .freshRSSAPIPassword
            case .mastodon: .mastodonAccessToken
            }

            do {
                // No credential is not a failure: an account added on another device arrives
                // without one and is signed in to later. Its id still has to move, or the sign-in
                // would store the secret under an id nothing points at any more.
                if let secret = try keychain.string(for: purpose, key: account.id.uuidString) {
                    try keychain.setString(secret, for: purpose, key: new.uuidString)
                    // Only once the new copy is safely written. The reverse order risks an account
                    // with no credential at all if the write fails.
                    try keychain.remove(for: purpose, key: account.id.uuidString)
                }
                moved[account.id] = new
            } catch {
                continue
            }
        }

        return moved
    }

    // MARK: - Rewriting the store

    private static func rewriteSources(
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        let rows = try context.fetch(FetchDescriptor<CachedSource>())
        var taken = Set(rows.map(\.id))

        for row in rows {
            guard let new = map[row.accountID] else { continue }
            guard let id = rewrite(id: row.id, using: map) else { continue }
            guard claim(id, in: &taken) else {
                context.delete(row)
                report.discardedDuplicates += 1
                continue
            }
            taken.remove(row.id)
            row.id = id
            row.accountID = new
            report.sources += 1
        }
    }

    private static func rewriteItems(
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        let rows = try context.fetch(FetchDescriptor<CachedItem>())
        var taken = Set(rows.map(\.id))

        for row in rows {
            guard let new = map[row.accountID] else { continue }
            guard let id = rewrite(id: row.id, using: map) else { continue }
            guard claim(id, in: &taken) else {
                context.delete(row)
                report.discardedDuplicates += 1
                continue
            }
            taken.remove(row.id)
            row.id = id
            row.accountID = new
            if let sourceID = rewrite(id: row.sourceID, using: map) {
                row.sourceID = sourceID
            }
            // Both keys carry the item id as their tie-break, so both move with it. Missing this
            // is the difference between a store that sorts and one whose every position lands in
            // the wrong place.
            row.sortKeyRaw = rewrite(sortKeyRaw: row.sortKeyRaw, using: map)
            row.ingestKeyRaw = rewrite(sortKeyRaw: row.ingestKeyRaw, using: map)
            report.items += 1
        }
    }

    private static func rewriteReadLater(
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        let rows = try context.fetch(FetchDescriptor<ReadLaterEntry>())
        var taken = Set(rows.map(\.itemID))

        for row in rows {
            guard map[row.accountID] != nil else { continue }
            guard let itemID = rewrite(id: row.itemID, using: map) else { continue }
            guard claim(itemID, in: &taken) else {
                context.delete(row)
                report.discardedDuplicates += 1
                continue
            }
            taken.remove(row.itemID)

            // The old record is deleted on the server as well as replaced here. Unlike an account,
            // a Read Later record is matched by id alone, and this id names *this* device's copy —
            // the one every other device pulled and could not open, because it points at an item
            // id that only ever existed here. See the "empty reading pane" symptom.
            try SyncOutbox.recordReadLaterDeletion(itemID: row.itemID, in: context)

            row.itemID = itemID
            row.accountID = map[row.accountID] ?? row.accountID
            if let sourceID = rewrite(id: row.sourceID, using: map) {
                row.sourceID = sourceID
            }
            row.sortKeyRaw = rewrite(sortKeyRaw: row.sortKeyRaw, using: map)
            try SyncOutbox.record(row, in: context)
            report.readLaterEntries += 1
        }
    }

    private static func rewritePositions(
        deviceID: String,
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        let rows = try context.fetch(FetchDescriptor<PositionMark>())
        var taken = Set(rows.map(\.key))

        for row in rows {
            // The mark itself names an item, whoever wrote it, so it is rewritten even when the
            // scope is not — `All Items` on this device points at an item id from this store.
            let markSortKeyRaw = rewrite(sortKeyRaw: row.markSortKeyRaw, using: map)
            let scope = rewrite(scope: row.scope, using: map)

            guard markSortKeyRaw != row.markSortKeyRaw || scope != nil else { continue }
            row.markSortKeyRaw = markSortKeyRaw

            if let scope {
                let key = PositionMark.key(scope: scope, deviceID: row.deviceID)
                guard claim(key, in: &taken) else {
                    context.delete(row)
                    report.discardedDuplicates += 1
                    continue
                }
                taken.remove(row.key)

                // Rows belonging to *other* devices are rewritten too, and that is deliberate: a
                // device that adopted this device's account id — which pulled accounts used to do
                // — writes positions in this id space, and they become usable here the moment
                // they are renamed. What must not happen is this device pushing them, since the
                // record is that device's to own. Only its own rows are queued below.
                if row.deviceID == deviceID {
                    try SyncOutbox.recordPositionDeletion(key: row.key, in: context)
                }

                row.key = key
                row.scopeRaw = scope.rawValue
            }

            if row.deviceID == deviceID {
                try SyncOutbox.record(row, in: context)
            }
            report.positionMarks += 1
        }
    }

    private static func rewriteCursors(
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        let rows = try context.fetch(FetchDescriptor<SyncCursor>())
        var taken = Set(rows.map(\.key))

        for row in rows {
            guard let new = map[row.accountID] else { continue }
            let key = SyncCursor.key(accountID: new, streamKey: row.streamKey)
            guard claim(key, in: &taken) else {
                // A cursor is ingest bookkeeping, so losing one costs a longer walk and nothing
                // else. It is the one row here that can simply be dropped.
                context.delete(row)
                report.discardedDuplicates += 1
                continue
            }
            taken.remove(row.key)
            row.key = key
            row.accountID = new
            // The ids this cursor remembers are the *provider's* own, not this app's, so they
            // survive the rename untouched — which is what keeps a migrated store from re-walking
            // every feed from the beginning.
            report.cursors += 1
        }
    }

    private static func rewriteFilters(
        in context: ModelContext,
        using map: [UUID: UUID],
        into report: inout Report
    ) throws {
        for rule in try context.fetch(FetchDescriptor<FilterRule>()) {
            let rewritten: FilterScope
            switch rule.scope {
            case .account(let accountID):
                guard let new = map[accountID] else { continue }
                rewritten = .account(new)
            case .source(let id):
                guard let new = rewrite(id: id, using: map) else { continue }
                rewritten = .source(new)
            case .everywhere:
                continue
            }

            rule.scope = rewritten
            // Pushed, unlike the other rewrites, because a rule's *id* does not change — so the
            // other devices are holding this same rule with a scope naming an account id only this
            // device ever had. They cannot fix it themselves: their own migration maps their ids,
            // not this one's. Sending the corrected rule fixes it everywhere at once, and since
            // the derived ids are the same on every device, two devices sending it are sending the
            // same thing.
            rule.updatedAt = .now
            try SyncOutbox.record(rule, in: context)
            report.filterRules += 1
        }
    }

    // MARK: - Rewriting one value

    /// Whether `id` is still free, claiming it when it is.
    private static func claim(_ id: String, in taken: inout Set<String>) -> Bool {
        taken.insert(id).inserted
    }

    /// `<kind>:<account id>:<provider id>` with the account component replaced.
    ///
    /// Split at most twice, so a provider id containing colons of its own survives intact — the
    /// same rule `ThresholdService.stableItemKey(in:)` takes these apart by.
    ///
    /// - Returns: `nil` when this is not a namespaced id, or names an account not being migrated.
    static func rewrite(id: String, using map: [UUID: UUID]) -> String? {
        let parts = id.split(
            separator: SourceIdentifier.separator,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              let old = UUID(uuidString: String(parts[1])),
              let new = map[old]
        else { return nil }
        return "\(parts[0])\(SourceIdentifier.separator)\(new.uuidString)\(SourceIdentifier.separator)\(parts[2])"
    }

    /// A sort key with the item id inside it rewritten, or the key unchanged.
    ///
    /// Rebuilt through `SortKey` rather than by string surgery, so the millisecond field keeps the
    /// exact padding the ordering depends on.
    static func rewrite(sortKeyRaw: String, using map: [UUID: UUID]) -> String {
        let key = SortKey(rawValue: sortKeyRaw)
        guard let millis = key.millis,
              let id = key.id,
              let rewritten = rewrite(id: id, using: map)
        else { return sortKeyRaw }
        return SortKey(millis: millis, id: rewritten).rawValue
    }

    /// The same scope addressed by the account's new id, or `nil` when it does not name one.
    ///
    /// `.all`, `.folder`, `.readLater`, `.lateArrivals` and `.filtered` carry no account id, which
    /// is exactly why those were the only positions that ever synced.
    public static func rewrite(scope: ScopeID, using map: [UUID: UUID]) -> ScopeID? {
        switch scope {
        case .source(let id):
            guard let rewritten = rewrite(id: id, using: map) else { return nil }
            return .source(rewritten)
        case .mastodonHome(let accountID):
            guard let new = map[accountID] else { return nil }
            return .mastodonHome(accountID: new)
        case .all, .folder, .readLater, .lateArrivals, .filtered:
            return nil
        }
    }
}
