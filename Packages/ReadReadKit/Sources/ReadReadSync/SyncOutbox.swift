import Foundation
import ReadReadModel
import SwiftData

/// Turns a local change into a queued push.
///
/// ## Why this is called explicitly rather than derived
///
/// The tempting alternative is to observe `ModelContext` saves and diff what changed. That is what
/// the outbox exists to avoid: a diff cannot tell a locally-deleted record from one that simply has
/// not been pulled yet, so every tombstone would resurrect on the next sync. The outbox has to be
/// written by whoever made the change, while it still knows what the change *was*.
///
/// The risk that buys is a mutation site forgetting to call this. It is contained by keeping the
/// set of synced mutations small and naming them all here — there are five — and by writing the
/// outbox row into the **same `ModelContext` as the change**, so the caller's single `save()`
/// commits both or neither. A change that persisted without its push record would be silently
/// stranded on one device, which is the failure this shape rules out.
public enum SyncOutbox {

    // MARK: - Positions

    /// Queues a reading position.
    ///
    /// Positions are the highest-frequency record by far — one per scope per settled scroll — but
    /// they are also the smallest, and `PendingChange` keeps one row per record, so a scope that is
    /// scrolled through repeatedly still pushes once.
    public static func record(_ mark: PositionMark, in context: ModelContext) throws {
        try enqueue(
            collection: .position,
            recordID: mark.key,
            payload: PositionPayload(mark),
            in: context
        )
    }

    /// Queues the removal of a position record this device owns.
    ///
    /// The only caller is ``AccountIDMigration``, and the distinction it relies on is that a
    /// position record is matched by **id alone** on the receiving side — unlike an account, whose
    /// tombstone is matched by identity and would therefore delete the account everywhere. The key
    /// here names one scope on one device, so deleting it can only ever remove the row this device
    /// has just rewritten, and it clears the copies other devices pulled of a scope id that no
    /// longer exists anywhere.
    ///
    /// Takes the key rather than the row, because by the time this is called the row is carrying
    /// its *new* key and the old one is only known to the caller.
    public static func recordPositionDeletion(key: String, in context: ModelContext) throws {
        try enqueueDeletion(collection: .position, recordID: key, in: context)
    }

    // MARK: - Read Later

    public static func record(_ entry: ReadLaterEntry, in context: ModelContext) throws {
        try enqueue(
            collection: .readLater,
            recordID: entry.itemID,
            payload: ReadLaterPayload(entry),
            in: context
        )
    }

    public static func recordReadLaterDeletion(itemID: String, in context: ModelContext) throws {
        try enqueueDeletion(collection: .readLater, recordID: itemID, in: context)
    }

    /// Queues whichever side of a toggle actually happened.
    public static func record(_ toggle: ReadLaterService.Toggle, in context: ModelContext) throws {
        switch toggle {
        case .saved(let itemID):
            guard let entry = try ReadLaterService.entry(for: itemID, in: context) else { return }
            try record(entry, in: context)
        case .removed(let itemID):
            try recordReadLaterDeletion(itemID: itemID, in: context)
        }
    }

    // MARK: - Filters

    public static func record(_ rule: FilterRule, in context: ModelContext) throws {
        try enqueue(
            collection: .filter,
            recordID: rule.id.uuidString,
            payload: FilterPayload(rule),
            in: context
        )
    }

    public static func recordFilterDeletion(id: UUID, in context: ModelContext) throws {
        try enqueueDeletion(collection: .filter, recordID: id.uuidString, in: context)
    }

    // MARK: - Accounts

    /// Queues an account — its servers and usernames, never a credential. See ``AccountPayload``.
    public static func record(_ account: AccountRecord, in context: ModelContext) throws {
        try enqueue(
            collection: .account,
            recordID: account.id.uuidString,
            payload: AccountPayload(account),
            in: context
        )
    }

    /// Queues an account's removal, saying *which account* rather than only which id.
    ///
    /// The one tombstone in the app that carries a payload, and it has to. Every device mints its
    /// own `UUID` when an account is signed in to, so the same account can be `A` here and `C`
    /// there — and a tombstone naming only `A` is a message about a row the other device has never
    /// heard of. It deleted nothing, and the account the reader removed came straight back at the
    /// next refresh on every device but the one they removed it on.
    ///
    /// So it names the account the way ``AccountIdentity`` does — kind, server, username, all of
    /// them fields the live record already syncs, and none of them a credential. The receiving
    /// device matches on that and removes its own copy, whatever id that copy carries.
    ///
    /// Taken as a record rather than an id so the payload cannot be built from a row that has
    /// already been deleted: by the time a caller has an id to hand, the account it named is
    /// usually gone.
    public static func recordAccountDeletion(_ account: AccountRecord, in context: ModelContext) throws {
        let data = try SyncPayloadCoding.encoder.encode(AccountPayload(account))
        try upsert(
            collection: .account,
            recordID: account.id.uuidString,
            payload: data,
            isDeletion: true,
            in: context
        )
    }

    // MARK: - Queueing

    private static func enqueue(
        collection: SyncCollection,
        recordID: String,
        payload: some Encodable,
        in context: ModelContext
    ) throws {
        let data = try SyncPayloadCoding.encoder.encode(payload)
        try upsert(collection: collection, recordID: recordID, payload: data, isDeletion: false, in: context)
    }

    private static func enqueueDeletion(
        collection: SyncCollection,
        recordID: String,
        in context: ModelContext
    ) throws {
        try upsert(collection: collection, recordID: recordID, payload: Data(), isDeletion: true, in: context)
    }

    private static func upsert(
        collection: SyncCollection,
        recordID: String,
        payload: Data,
        isDeletion: Bool,
        in context: ModelContext
    ) throws {
        let key = PendingChange.key(collection: collection, recordID: recordID)
        var descriptor = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        guard let existing = try context.fetch(descriptor).first else {
            context.insert(PendingChange(
                collection: collection,
                recordID: recordID,
                payload: payload,
                isDeletion: isDeletion
            ))
            return
        }

        // A re-encode that produces the same bytes is a write that changed nothing the other
        // devices can see — re-saving a Read Later entry with an identical snapshot, or applying a
        // pulled record and queueing it straight back. `SyncPayloadCoding.encoder` sorts its keys
        // precisely so this comparison is meaningful, and skipping the touch keeps the record from
        // being pushed again on every sync.
        guard existing.payload != payload || existing.isDeletion != isDeletion else { return }

        existing.payload = payload
        existing.isDeletion = isDeletion
        existing.queuedAt = .now
        // Reset, because this is different content: the previous rejection said nothing about
        // whether the server will accept what is queued now.
        existing.failureCount = 0
    }
}
