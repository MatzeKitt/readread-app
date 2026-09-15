import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftData

/// Removes the unusable second copy of an account that arrived by sync.
///
/// Stops the duplicates already sitting in a store from failing every refresh for ever. New ones
/// cannot form — `SyncStore` recognises them on the way in — but a store that pre-dates that check
/// still holds them, and nothing else would ever clear them.
///
/// ## Why this must not push a deletion
///
/// The obvious implementation deletes the row the way the Settings screen does, through
/// `SyncOutbox.recordAccountDeletion`. That would be a disaster: the copy this device cannot use
/// is the copy the *other* device authenticates with, so pushing its tombstone would delete a
/// working account on the other device and take its feeds and reading positions with it. The
/// deletion is therefore local only, and the row simply never comes back because the incoming
/// record is now recognised as a duplicate and dropped.
public enum AccountDeduplication {

    /// Keeps one record per identity, preferring whichever one this device can actually sign in as.
    ///
    /// - Returns: The display names of the records removed, for reporting.
    @discardableResult
    public static func removeUnusableDuplicates(
        keychain: KeychainStore = KeychainStore(),
        in context: ModelContext
    ) throws -> [String] {
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        guard accounts.count > 1 else { return [] }

        var groups: [AccountIdentity: [AccountRecord]] = [:]
        for account in accounts {
            groups[AccountIdentity(account), default: []].append(account)
        }

        var removed: [String] = []
        for (_, group) in groups where group.count > 1 {
            // Credentials decide it. Whichever copy this device holds a secret for is the one it
            // can refresh with, whatever id it happens to carry.
            let usable = group.filter { hasCredential(for: $0, keychain: keychain) }

            // Keeping the oldest when none is usable, and when *several* are: neither case can be
            // resolved by credentials, and `createdAt` at least makes the choice stable rather
            // than dependent on fetch order — two devices reaching different answers here would
            // trade deletions back and forth.
            let survivors = usable.isEmpty ? group : usable
            guard let keep = survivors.min(by: { $0.createdAt < $1.createdAt }) else { continue }

            for account in group where account.id != keep.id {
                removed.append(account.displayName)
                // Items and sources are namespaced by account id, so the doomed copy's rows go
                // with it. It never fetched anything, so there is nothing of the user's here.
                let id = account.id
                try context.delete(model: CachedItem.self, where: #Predicate { $0.accountID == id })
                try context.delete(model: CachedSource.self, where: #Predicate { $0.accountID == id })
                try context.delete(model: SyncCursor.self, where: #Predicate { $0.accountID == id })
                context.delete(account)
            }
        }

        if !removed.isEmpty {
            try context.save()
        }
        return removed
    }

    private static func hasCredential(for account: AccountRecord, keychain: KeychainStore) -> Bool {
        AccountConnections(keychain: keychain)
            .hasCredential(forAccountID: account.id, kind: account.kind)
    }
}
