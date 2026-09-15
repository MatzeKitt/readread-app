import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Resolving an item id that another device wrote.
///
/// The bug these exist for: a `ReadLaterEntry` carries the item id as the *saving* device knew it,
/// and an item id embeds a per-device account UUID. So every item saved on the phone named a row
/// the Mac did not have, the reading pane looked the id up verbatim, found nothing, and showed an
/// empty pane — which read as "Read Later items cannot be opened".
@Suite("Item resolution")
struct ItemResolutionTests {

    private let localAccount = UUID()
    private let foreignAccount = UUID()

    private func makeContext() throws -> ModelContext {
        ModelContext(try ReadReadStore.inMemoryContainer())
    }

    private func insertAccount(_ id: UUID, in context: ModelContext) {
        context.insert(
            AccountRecord(
                id: id,
                kind: .freshRSS,
                displayName: "FreshRSS",
                serverURLString: "https://example.com",
                username: "reader"
            )
        )
    }

    @discardableResult
    private func insertItem(id: String, in context: ModelContext) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        let item = CachedItem(
            id: id,
            sourceID: "freshrss:\(localAccount.uuidString):feed/1",
            accountID: localAccount,
            kind: .article,
            title: "A fine widget",
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: key,
            ingestKey: key
        )
        context.insert(item)
        return item
    }

    @Test("An id this device wrote resolves directly")
    func exactMatch() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)
        let id = SourceIdentifier.freshRSSItem(accountID: localAccount, itemID: "1f2e")
        insertItem(id: id, in: context)

        #expect(try ItemResolution.cachedItem(for: id, in: context)?.id == id)
    }

    /// The whole point. Same article, same provider id, different account UUID.
    @Test("An id from another device resolves to the local copy")
    func foreignAccountResolves() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)
        let local = SourceIdentifier.freshRSSItem(accountID: localAccount, itemID: "1f2e")
        insertItem(id: local, in: context)

        let foreign = SourceIdentifier.freshRSSItem(accountID: foreignAccount, itemID: "1f2e")

        #expect(try ItemResolution.cachedItem(for: foreign, in: context)?.id == local)
    }

    /// A different article on the same account must not be mistaken for it. The provider id is the
    /// only part that carries identity, so it has to match exactly.
    @Test("A different provider id does not resolve")
    func differentItemDoesNotResolve() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)
        insertItem(id: SourceIdentifier.freshRSSItem(accountID: localAccount, itemID: "1f2e"), in: context)

        let other = SourceIdentifier.freshRSSItem(accountID: foreignAccount, itemID: "abcd")

        #expect(try ItemResolution.cachedItem(for: other, in: context) == nil)
    }

    /// A Mastodon status id and a FreshRSS hex are namespaced by the prefix, and the prefix is
    /// carried over from the id being resolved rather than guessed from the account.
    @Test("The kind prefix is not crossed")
    func kindIsNotCrossed() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)
        insertItem(id: SourceIdentifier.freshRSSItem(accountID: localAccount, itemID: "1f2e"), in: context)

        let status = SourceIdentifier.mastodonItem(accountID: foreignAccount, statusID: "1f2e")

        #expect(try ItemResolution.cachedItem(for: status, in: context) == nil)
    }

    /// Pruned, or never fetched here. An ordinary state — the caller falls back to the snapshot.
    @Test("An item this device does not have resolves to nothing")
    func absentItem() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)

        let id = SourceIdentifier.freshRSSItem(accountID: foreignAccount, itemID: "1f2e")

        #expect(try ItemResolution.cachedItem(for: id, in: context) == nil)
    }

    /// Nothing to translate against, and nothing to crash on either: a store whose accounts have
    /// not synced yet is the state a fresh install is in for its first few seconds.
    @Test("With no accounts, only an exact match resolves")
    func noAccounts() throws {
        let context = try makeContext()
        let id = SourceIdentifier.freshRSSItem(accountID: localAccount, itemID: "1f2e")
        insertItem(id: id, in: context)

        #expect(try ItemResolution.cachedItem(for: id, in: context)?.id == id)
        #expect(
            try ItemResolution.cachedItem(
                for: SourceIdentifier.freshRSSItem(accountID: foreignAccount, itemID: "1f2e"),
                in: context
            ) == nil
        )
    }

    /// Ids are built here, but they arrive from sync — so a malformed one has to come back empty
    /// rather than build a candidate out of half a string.
    @Test("A malformed id yields no candidates")
    func malformedID() throws {
        let context = try makeContext()
        insertAccount(localAccount, in: context)

        #expect(try ItemResolution.localEquivalents(of: "freshrss", in: context).isEmpty)
        #expect(try ItemResolution.localEquivalents(of: "freshrss:\(localAccount.uuidString):", in: context).isEmpty)
        #expect(try ItemResolution.localEquivalents(of: ":\(localAccount.uuidString):1f2e", in: context).isEmpty)
    }
}
