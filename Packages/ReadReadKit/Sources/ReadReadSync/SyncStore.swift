import Foundation
import ReadReadModel
import SwiftData

/// Applies pulled records to the store and drains the outbox into pushes.
///
/// **All merge policy lives here.** The server is a revision-numbered blob store that never looks
/// inside a payload, so this is the single place that knows what a conflict means for each
/// collection — and there is exactly one such place on purpose.
@ModelActor
public actor SyncStore {

    /// How far ahead of local time an incoming position's timestamp may be before it is clamped.
    ///
    /// Generous, because ordinary clock drift between two of the user's own devices is seconds and
    /// clamping a legitimate record would lose a real position. It only needs to be tight enough
    /// to stop a wildly wrong clock from winning forever.
    private static let clockSkewTolerance: TimeInterval = 60 * 60

    // MARK: - Cursor

    private func state() throws -> SyncState {
        var descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.id == "default" })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        let created = SyncState()
        modelContext.insert(created)
        return created
    }

    public func pullCursor() throws -> Int {
        try state().pullCursor
    }

    public func recordFailure(_ description: String) throws {
        try state().lastErrorDescription = description
        try modelContext.save()
    }

    // MARK: - Pushing

    /// Turns queued local changes into push records.
    public func pendingPushRecords(limit: Int = 500) throws -> [SyncPushRecord] {
        var descriptor = FetchDescriptor<PendingChange>(
            sortBy: [SortDescriptor(\.queuedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor).map { change in
            SyncPushRecord(
                collection: change.collection,
                id: change.recordID,
                deleted: change.isDeletion,
                // A deletion's payload is sent rather than blanked. It is empty for every
                // collection but accounts, whose tombstones name the account they are for — see
                // `SyncOutbox.recordAccountDeletion(_:in:)`.
                payload: String(decoding: change.payload, as: UTF8.self)
            )
        }
    }

    /// Removes outbox entries the server has accepted.
    public func clearPending(_ records: [SyncPushRecord]) throws {
        let keys = Set(records.map { PendingChange.key(collection: $0.collection, recordID: $0.id) })
        guard !keys.isEmpty else { return }

        let queued = try modelContext.fetch(FetchDescriptor<PendingChange>())
        for change in queued where keys.contains(change.key) {
            modelContext.delete(change)
        }
        try state().lastPushedAt = .now
        try modelContext.save()
    }

    /// Drops outbox entries the server rejected outright.
    ///
    /// A 400 means the record is malformed, which will not change on retry — leaving it queued
    /// would block every later change behind it forever. The failure count is kept so a genuinely
    /// transient rejection is retried a couple of times first.
    public func failPending(_ records: [SyncPushRecord], permanent: Bool) throws {
        let keys = Set(records.map { PendingChange.key(collection: $0.collection, recordID: $0.id) })
        let queued = try modelContext.fetch(FetchDescriptor<PendingChange>())

        for change in queued where keys.contains(change.key) {
            change.failureCount += 1
            if permanent || change.failureCount >= 5 {
                modelContext.delete(change)
            }
        }
        try modelContext.save()
    }

    /// Queues a local change for the next push.
    public func enqueue(collection: SyncCollection, recordID: String, payload: String) throws {
        try enqueue(collection: collection, recordID: recordID, payload: Data(payload.utf8), isDeletion: false)
    }

    public func enqueueDeletion(collection: SyncCollection, recordID: String) throws {
        try enqueue(collection: collection, recordID: recordID, payload: Data(), isDeletion: true)
    }

    private func enqueue(
        collection: SyncCollection,
        recordID: String,
        payload: Data,
        isDeletion: Bool
    ) throws {
        let key = PendingChange.key(collection: collection, recordID: recordID)
        var descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            // One row per record: a second edit replaces the queued payload rather than queueing
            // behind it, because only the final state is worth sending.
            existing.payload = payload
            existing.isDeletion = isDeletion
            existing.queuedAt = .now
            existing.failureCount = 0
        } else {
            modelContext.insert(PendingChange(
                collection: collection,
                recordID: recordID,
                payload: payload,
                isDeletion: isDeletion
            ))
        }
        try modelContext.save()
    }

    // MARK: - Applying

    /// Applies a pulled page and advances the cursor, in one transaction.
    ///
    /// - Returns: How many records changed something locally.
    @discardableResult
    public func apply(_ page: SyncChangesPage) throws -> Int {
        try applyReportingCollections(page).applied
    }

    /// Applies a pulled page and says *what kind* of thing changed.
    ///
    /// The count alone is not enough, because some collections need work afterwards that only the
    /// caller can do. A filter rule is the case that forced this: applying one updates the rule and
    /// nothing else, while what actually hides an item is the stored `isFilteredOut` column on
    /// every row. So a filter created on one device synced to the other, appeared in its filter
    /// list, and hid nothing at all — until the reader happened to open the editor and touch
    /// something, which is what re-applies rules locally.
    @discardableResult
    public func applyReportingCollections(
        _ page: SyncChangesPage
    ) throws -> (applied: Int, collections: Set<SyncCollection>, removedAccountIDs: Set<UUID>) {
        // Records with a queued local change are skipped. Our own edit has not been pushed yet, so
        // the server's copy is by definition older — applying it would silently discard work the
        // user just did.
        let pendingKeys = Set(try modelContext.fetch(FetchDescriptor<PendingChange>()).map(\.key))

        var applied = 0
        var collections: Set<SyncCollection> = []
        // Reset per page rather than declared inside the loop: an account deletion has one effect
        // this actor cannot carry out itself — forgetting the account's Keychain items — and the
        // ids it happened to are the only way the caller can know which.
        removedAccountIDs = []

        for record in page.records {
            let key = PendingChange.key(collection: record.collection, recordID: record.id)
            if pendingKeys.contains(key) { continue }

            do {
                if try applyOne(record) {
                    applied += 1
                    collections.insert(record.collection)
                }
            } catch {
                // One malformed record must not abort the whole page, or a single bad payload from
                // any device would wedge sync permanently for all of them.
                continue
            }
        }

        let syncState = try state()
        syncState.pullCursor = max(syncState.pullCursor, page.maxRevision)
        syncState.lastPulledAt = .now
        syncState.lastErrorDescription = nil
        try modelContext.save()

        return (applied, collections, removedAccountIDs)
    }

    /// Accounts the page being applied removed. Collected by ``applyAccount(_:)``, which is several
    /// frames down from where the result is assembled.
    private var removedAccountIDs: Set<UUID> = []

    private func applyOne(_ record: SyncRecord) throws -> Bool {
        switch record.collection {
        case .position: try applyPosition(record)
        case .readLater: try applyReadLater(record)
        case .filter: try applyFilter(record)
        case .account: try applyAccount(record)
        }
    }

    /// Positions cannot conflict — each device owns its own row — but a stale copy can still
    /// arrive, including this device's own echo. Applying only when the incoming value supersedes
    /// the stored one keeps that harmless.
    private func applyPosition(_ record: SyncRecord) throws -> Bool {
        let key = record.id
        var descriptor = FetchDescriptor<PositionMark>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if record.deleted {
            guard let existing else { return false }
            modelContext.delete(existing)
            return true
        }

        let payload = try SyncPayloadCoding.decode(PositionPayload.self, from: record.payload)
        guard let scope = ScopeID(rawValue: payload.scope) else {
            throw SyncError.unexpectedResponse("Unknown scope '\(payload.scope)'")
        }

        // Clamped because the reduction orders positions by wall clock, and a device whose clock is
        // badly wrong — one that lost its battery, say — would otherwise write a timestamp far in
        // the future and hold every scope's position hostage until it was next used.
        let updatedAt = min(payload.updatedAt, Date.now.addingTimeInterval(Self.clockSkewTolerance))

        guard let existing else {
            let mark = PositionMark(
                scope: scope,
                deviceID: payload.deviceID,
                markSortKey: SortKey(rawValue: payload.markSortKey),
                updatedAt: updatedAt
            )
            modelContext.insert(mark)
            return true
        }

        guard payload.supersedes(updatedAt: existing.updatedAt) else { return false }

        existing.markSortKeyRaw = payload.markSortKey
        // The remote timestamp, deliberately, not `.now`. Stamping the local clock here would make
        // every pulled position instantly the most recent one and hand this device's own view of
        // where it is reading to whichever record happened to arrive last.
        existing.updatedAt = updatedAt
        return true
    }

    private func applyReadLater(_ record: SyncRecord) throws -> Bool {
        let itemID = record.id
        var descriptor = FetchDescriptor<ReadLaterEntry>(predicate: #Predicate { $0.itemID == itemID })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if record.deleted {
            guard let existing else { return false }
            modelContext.delete(existing)
            return true
        }

        let payload = try SyncPayloadCoding.decode(ReadLaterPayload.self, from: record.payload)

        if let existing {
            // Already present. Re-saving the same entry would only churn the row and its
            // `addedAt`, which is what the list is ordered by.
            guard existing.addedAt != payload.addedAt else { return false }
            existing.addedAt = payload.addedAt
            return true
        }

        modelContext.insert(ReadLaterEntry(
            itemID: payload.itemID,
            sourceID: payload.sourceID,
            accountID: UUID(uuidString: payload.accountID) ?? UUID(),
            kind: ItemKind(rawValue: payload.kind) ?? .article,
            title: payload.title,
            sourceTitle: payload.sourceTitle,
            authorName: payload.authorName,
            urlString: payload.urlString,
            excerpt: payload.excerpt,
            iconURLString: payload.iconURLString,
            publishedAt: payload.publishedAt,
            sortKey: SortKey(rawValue: payload.sortKey),
            addedAt: payload.addedAt
        ))
        return true
    }

    private func applyFilter(_ record: SyncRecord) throws -> Bool {
        guard let id = UUID(uuidString: record.id) else {
            throw SyncError.unexpectedResponse("Filter id '\(record.id)' is not a UUID")
        }
        var descriptor = FetchDescriptor<FilterRule>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if record.deleted {
            guard let existing else { return false }
            modelContext.delete(existing)
            return true
        }

        let payload = try SyncPayloadCoding.decode(FilterPayload.self, from: record.payload)

        if let existing {
            // Last writer wins on the rule's own `updatedAt`, which the editing device sets. An
            // older edit arriving late must not undo a newer one.
            guard payload.updatedAt > existing.updatedAt else { return false }
            existing.name = payload.name
            existing.pattern = payload.pattern
            existing.fieldsRaw = payload.fields
            existing.matchKindRaw = payload.matchKind
            existing.isCaseSensitive = payload.isCaseSensitive
            existing.scope = payload.scope
            existing.isEnabled = payload.isEnabled
            existing.updatedAt = payload.updatedAt
            return true
        }

        let rule = FilterRule(
            id: id,
            name: payload.name,
            pattern: payload.pattern,
            fields: FilterFields(rawValue: payload.fields),
            matchKind: FilterMatchKind(rawValue: payload.matchKind) ?? .contains,
            isCaseSensitive: payload.isCaseSensitive,
            scope: payload.scope,
            isEnabled: payload.isEnabled,
            createdAt: payload.createdAt
        )
        rule.updatedAt = payload.updatedAt
        modelContext.insert(rule)
        return true
    }

    /// A local account with the same identity, whatever id it carries.
    private func localAccount(matching identity: AccountIdentity) throws -> AccountRecord? {
        try modelContext.fetch(FetchDescriptor<AccountRecord>())
            .first { AccountIdentity($0) == identity }
    }

    private func applyAccount(_ record: SyncRecord) throws -> Bool {
        guard let id = UUID(uuidString: record.id) else {
            throw SyncError.unexpectedResponse("Account id '\(record.id)' is not a UUID")
        }
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if record.deleted {
            return try removeAccounts(named: record, knownAs: existing)
        }

        let payload = try SyncPayloadCoding.decode(AccountPayload.self, from: record.payload)

        if let existing {
            existing.displayName = payload.displayName
            existing.serverURLString = payload.serverURLString
            existing.username = payload.username
            existing.isEnabled = payload.isEnabled
            return true
        }

        // An account this device already has under a *different* id is the same account, and
        // inserting it would make a second, permanently broken copy of it.
        //
        // Each device mints its own `UUID` when you sign in, and the account list syncs by that id
        // while credentials — correctly — never leave the device that holds them. So signing in to
        // the same server on a second device produces two records, they cross, and both devices
        // end up with one working account and one that can never authenticate. On a real install
        // that copy failed every refresh, which dragged every healthy account into the retry
        // backoff with it, and the app went minutes at a time without making a single request.
        //
        // Matching on what actually identifies an account — its kind, server and username —
        // recognises the copy and drops it. See `AccountIdentity`.
        let identity = AccountIdentity(
            kindRaw: payload.kind,
            serverURLString: payload.serverURLString,
            username: payload.username
        )
        if try localAccount(matching: identity) != nil {
            // Deliberately not merged into the local row: this device's copy is the one it can
            // authenticate, and the incoming fields would only overwrite it with the same values.
            return false
        }

        // Otherwise genuinely new here — an account added on another device. It arrives with no
        // credential, so the user signs in to it on this device before it can fetch anything.
        modelContext.insert(AccountRecord(
            id: id,
            kind: AccountKind(rawValue: payload.kind) ?? .freshRSS,
            displayName: payload.displayName,
            serverURLString: payload.serverURLString,
            username: payload.username,
            createdAt: payload.createdAt,
            isEnabled: payload.isEnabled
        ))
        return true
    }

    /// Applies an account tombstone to every local copy of the account it names.
    ///
    /// ## Why an id is not enough
    ///
    /// Each device mints its own `UUID` for an account, so the row removed on a Mac can be sitting
    /// here under a different one. A tombstone matched only by id therefore deleted nothing on the
    /// very devices the removal was meant to reach, and the account carried on refreshing there —
    /// while on a device that *had* adopted the same id, it deleted the copy that device was signed
    /// in as. Neither is what "remove this account" means.
    ///
    /// So the tombstone names the account (see ``SyncOutbox/recordAccountDeletion(_:in:)``) and the
    /// match is on identity. An older server blanks the payload, in which case there is nothing to
    /// match on and this falls back to the id — the previous behaviour, no worse than it was.
    ///
    /// ## Why removing a local copy queues a tombstone of its own
    ///
    /// The server still holds a live record for *this* device's id. Deleting the row here without
    /// saying so would leave that record behind, and the account would reappear on the next device
    /// to sync from scratch. Each device therefore tombstones its own alias, once: a tombstone for
    /// an account already gone matches nothing and queues nothing, so this converges rather than
    /// bouncing between devices.
    ///
    /// This is the one place a deletion is pushed without the reader pressing Remove, and it is not
    /// the hazard `AccountDeduplication` refuses to go near. That one guesses which copy is
    /// redundant; this one is relaying a removal the reader actually asked for, to the same account
    /// under a different name.
    private func removeAccounts(named record: SyncRecord, knownAs existing: AccountRecord?) throws -> Bool {
        var doomed: [AccountRecord] = existing.map { [$0] } ?? []

        if let payload = try? SyncPayloadCoding.decode(AccountPayload.self, from: record.payload) {
            let identity = AccountIdentity(
                kindRaw: payload.kind,
                serverURLString: payload.serverURLString,
                username: payload.username
            )
            let aliases = try modelContext.fetch(FetchDescriptor<AccountRecord>())
                .filter { AccountIdentity($0) == identity && $0.id != existing?.id }
            for alias in aliases {
                // The server's live record for this id has to be retracted as well, or a device
                // syncing from scratch would pick the account up again from it.
                try SyncOutbox.recordAccountDeletion(alias, in: modelContext)
            }
            doomed.append(contentsOf: aliases)
        }

        guard !doomed.isEmpty else { return false }

        for account in doomed {
            let id = account.id
            // Everything ingested under the account goes with it, as it does when the account is
            // removed on this device. Items outlive their account otherwise: they are namespaced by
            // account id, so nothing would ever refresh, prune or open them again.
            try modelContext.delete(model: CachedItem.self, where: #Predicate { $0.accountID == id })
            try modelContext.delete(model: CachedSource.self, where: #Predicate { $0.accountID == id })
            try modelContext.delete(model: SyncCursor.self, where: #Predicate { $0.accountID == id })
            modelContext.delete(account)
            // The caller forgets its Keychain items. They are the one thing that outlives a deleted
            // account otherwise — a password or an OAuth token for an account nothing here can name
            // any more, sitting in the Keychain until the device is wiped.
            removedAccountIDs.insert(id)
        }
        return true
    }
}
