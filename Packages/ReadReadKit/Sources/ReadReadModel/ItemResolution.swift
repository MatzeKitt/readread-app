import Foundation
import SwiftData

/// Finds the cached item an id refers to, including when the id was written by another device.
///
/// ## Why an id needs resolving at all
///
/// A `CachedItem.id` is `freshrss:<account UUID>:<hex>`, and the account UUID is generated *per
/// device* when the account is added. So the same article is `freshrss:A:1f2e` on the Mac and
/// `freshrss:B:1f2e` on the phone — the provider's own id, the last component, is the only part
/// both devices agree on.
///
/// That is fine for the cache, which is per-device anyway, and it is fine for anything that
/// resolves ids against the store that wrote them. It is not fine for the records that *sync*:
/// a `ReadLaterEntry` carries the id of the item as the saving device knew it, so a saved article
/// arriving from the phone names a row the Mac does not have — and the reading pane, which looked
/// the id up verbatim, showed an empty pane for every item saved anywhere else. Which is the
/// second symptom of this design; see ``ThresholdService/localisedMark(_:in:)`` for the first.
///
/// The proper fix is deterministic account ids and a migration that rewrites the ids already
/// stored. Until that happens, this translates at the point of use: the local accounts are known,
/// so the handful of ids *this* device could have written for the same provider item can be
/// constructed exactly and looked up on the unique index, rather than scanning the item table for
/// a suffix.
public enum ItemResolution {

    /// The cached item for `itemID`, trying this device's own ids for the same provider item when
    /// the id itself is not present.
    ///
    /// Returns `nil` when the item is genuinely not cached — pruned, or never fetched here. That is
    /// an ordinary state rather than an error, and callers holding a synced snapshot (Read Later)
    /// are expected to fall back to it.
    public static func cachedItem(for itemID: String, in context: ModelContext) throws -> CachedItem? {
        var exact = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == itemID })
        exact.fetchLimit = 1
        if let found = try context.fetch(exact).first { return found }

        let candidates = try localEquivalents(of: itemID, in: context)
        guard !candidates.isEmpty else { return nil }

        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { candidates.contains($0.id) })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The ids this device would have written for the same provider item, one per local account.
    ///
    /// The foreign account's own id is left out: it has already been tried as the exact match, and
    /// including it would make a miss cost a second lookup for the same row.
    ///
    /// Every account is offered rather than the one whose kind matches, because the kind prefix is
    /// carried over from the id being resolved and a Mastodon status id cannot collide with a
    /// FreshRSS hex under it. The list is as long as the account list, which is a handful.
    static func localEquivalents(of itemID: String, in context: ModelContext) throws -> [String] {
        let parts = itemID.split(
            separator: SourceIdentifier.separator,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty else { return [] }

        let kind = String(parts[0])
        let foreignAccount = String(parts[1])
        let stable = String(parts[2])
        let separator = String(SourceIdentifier.separator)

        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        return accounts
            .map(\.id.uuidString)
            .filter { $0 != foreignAccount }
            .map { kind + separator + $0 + separator + stable }
    }
}
