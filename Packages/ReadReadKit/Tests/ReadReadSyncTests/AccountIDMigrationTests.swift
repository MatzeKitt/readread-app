import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// The re-keying that makes two devices agree on what an account — and therefore every feed,
/// article and scope inside it — is called.
///
/// These are the tests for the cause rather than the symptoms. Account ids used to be minted per
/// device and are embedded in every id the account produces, so a synced record naming one pointed
/// at a row the other device did not have: per-feed positions that never synced, a restored
/// position landing one item off, Read Later entries opening an empty pane. What is pinned here is
/// that the rewrite reaches *every* place an account id is stored, because one missed column is
/// enough to leave the store internally inconsistent — which is worse than the bug.
@Suite("Account id migration")
struct AccountIDMigrationTests {

    private static let device = "device-A"

    private func makeKeychain() -> KeychainStore {
        KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
    }

    private func account(
        id: UUID = UUID(),
        kind: AccountKind = .freshRSS,
        server: String = "https://rss.example.net",
        username: String = "matze"
    ) -> AccountRecord {
        AccountRecord(
            id: id,
            kind: kind,
            displayName: server,
            serverURLString: server,
            username: username
        )
    }

    /// A store as an older build left it: every id built around one random account UUID.
    private func populate(_ context: ModelContext, accountID: UUID) throws {
        let sourceID = SourceIdentifier.freshRSS(accountID: accountID, streamID: "feed/1")
        let itemID = SourceIdentifier.freshRSSItem(accountID: accountID, itemID: "a1")

        context.insert(CachedSource(
            id: sourceID,
            accountID: accountID,
            kind: .article,
            title: "Feed One",
            folderName: "News"
        ))

        let item = CachedItem(
            id: itemID,
            sourceID: sourceID,
            accountID: accountID,
            kind: .article,
            title: "An article",
            contentHTML: "<p>x</p>",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: itemID),
            ingestKey: SortKey(millis: 1_700_000_100_000, id: itemID)
        )
        context.insert(item)

        context.insert(ReadLaterEntry(
            itemID: itemID,
            sourceID: sourceID,
            accountID: accountID,
            kind: .article,
            title: "An article",
            sourceTitle: "Feed One",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: itemID)
        ))

        context.insert(SyncCursor(accountID: accountID, streamKey: "reading-list"))

        // The scope that could never sync, and the one that always could, so the pass can be shown
        // to touch the first without disturbing the second.
        let feedMark = PositionMark(
            scope: .source(sourceID),
            deviceID: Self.device,
            markSortKey: SortKey(millis: 1_700_000_000_000, id: itemID)
        )
        context.insert(feedMark)
        context.insert(PositionMark(
            scope: .all,
            deviceID: Self.device,
            markSortKey: SortKey(millis: 1_700_000_000_000, id: itemID)
        ))

        let rule = FilterRule(name: "Noise", pattern: "noise")
        rule.scope = .account(accountID)
        context.insert(rule)

        try context.save()
    }

    // MARK: - Deriving

    /// The property the whole fix rests on: two devices that have never spoken compute the same id.
    @Test("The derived id is the same for the same account written differently")
    func derivationIsStableAcrossSpellings() {
        let one = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "https://RSS.example.net/",
            username: " Matze "
        )
        let two = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "rss.example.net",
            username: "matze"
        )

        #expect(one.accountID == two.accountID)
    }

    /// And it is a real v5 UUID, so nothing downstream has to learn a new kind of id.
    @Test("The derived id is a version 5 UUID")
    func derivationIsVersionFive() {
        let id = AccountIdentity(
            kindRaw: AccountKind.mastodon.rawValue,
            serverURLString: "https://mastodon.social",
            username: "matze"
        ).accountID

        #expect(id.uuid.6 & 0xF0 == 0x50)
        #expect(id.uuid.8 & 0xC0 == 0x80)
    }

    /// Different accounts must not collide, including two accounts on one server — the case the
    /// username is in the derivation for.
    @Test("Different accounts derive different ids")
    func derivationSeparatesAccounts() {
        let mine = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "https://rss.example.net",
            username: "matze"
        )
        let other = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "https://rss.example.net",
            username: "someone"
        )
        let elsewhere = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "https://rss.example.org",
            username: "matze"
        )
        let mastodon = AccountIdentity(
            kindRaw: AccountKind.mastodon.rawValue,
            serverURLString: "https://rss.example.net",
            username: "matze"
        )

        #expect(Set([mine, other, elsewhere, mastodon].map(\.accountID)).count == 4)
    }

    // MARK: - Rewriting

    @Test("Every stored id moves to the derived account id")
    func rewritesEveryStoredID() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try populate(context, accountID: old)

        let derived = AccountIdentity(record).accountID
        let report = try AccountIDMigration.run(
            deviceID: Self.device,
            in: context,
            keychain: makeKeychain()
        )

        #expect(report.accounts == [old: derived])

        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        #expect(accounts.map(\.id) == [derived])

        let sources = try context.fetch(FetchDescriptor<CachedSource>())
        #expect(sources.map(\.accountID) == [derived])
        #expect(sources.map(\.id) == [SourceIdentifier.freshRSS(accountID: derived, streamID: "feed/1")])

        let newItemID = SourceIdentifier.freshRSSItem(accountID: derived, itemID: "a1")
        let items = try context.fetch(FetchDescriptor<CachedItem>())
        #expect(items.map(\.id) == [newItemID])
        #expect(items.map(\.accountID) == [derived])
        #expect(items.map(\.sourceID) == [SourceIdentifier.freshRSS(accountID: derived, streamID: "feed/1")])
        // The tie-break inside both keys moves with the item, or every comparison against a
        // position would land somewhere else.
        #expect(items.first?.sortKey == SortKey(millis: 1_700_000_000_000, id: newItemID))
        #expect(items.first?.ingestKeyRaw == SortKey(millis: 1_700_000_100_000, id: newItemID).rawValue)

        let saved = try context.fetch(FetchDescriptor<ReadLaterEntry>())
        #expect(saved.map(\.itemID) == [newItemID])
        #expect(saved.first?.sortKey == SortKey(millis: 1_700_000_000_000, id: newItemID))

        let cursors = try context.fetch(FetchDescriptor<SyncCursor>())
        #expect(cursors.map(\.accountID) == [derived])
        #expect(cursors.map(\.key) == [SyncCursor.key(accountID: derived, streamKey: "reading-list")])

        let rules = try context.fetch(FetchDescriptor<FilterRule>())
        #expect(rules.map(\.scope) == [.account(derived)])
    }

    /// The point of the exercise: a per-feed position now has a key the other device will write
    /// too, instead of one only this device could ever produce.
    @Test("A feed's position is re-keyed into the shared id space")
    func rewritesFeedScopedPositions() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try populate(context, accountID: old)

        let derived = AccountIdentity(record).accountID
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: makeKeychain())

        let expected = ScopeID.source(SourceIdentifier.freshRSS(accountID: derived, streamID: "feed/1"))
        let marks = try context.fetch(FetchDescriptor<PositionMark>())
        let feed = try #require(marks.first { $0.scope != .all })

        #expect(feed.scope == expected)
        #expect(feed.key == PositionMark.key(scope: expected, deviceID: Self.device))
        #expect(feed.markSortKey.id == SourceIdentifier.freshRSSItem(accountID: derived, itemID: "a1"))
    }

    /// `All Items` never had an account id in its scope — it is one of the two that always synced
    /// — but the *mark* it holds names an item, and that does move.
    @Test("An account-free scope keeps its key and still has its mark rewritten")
    func rewritesMarksOfSharedScopes() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try populate(context, accountID: old)

        let derived = AccountIdentity(record).accountID
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: makeKeychain())

        let marks = try context.fetch(FetchDescriptor<PositionMark>())
        let all = try #require(marks.first { $0.scope == .all })

        #expect(all.key == PositionMark.key(scope: .all, deviceID: Self.device))
        #expect(all.markSortKey.id == SourceIdentifier.freshRSSItem(accountID: derived, itemID: "a1"))
    }

    /// A position row written by *another* device in this id space is rewritten too — it becomes
    /// usable — but it stays that device's to report.
    @Test("Another device's rows are rewritten but not queued for push")
    func doesNotClaimAnotherDevicesRows() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try populate(context, accountID: old)

        let sourceID = SourceIdentifier.freshRSS(accountID: old, streamID: "feed/1")
        let foreign = PositionMark(
            scope: .source(sourceID),
            deviceID: "device-B",
            markSortKey: SortKey(millis: 1_700_000_000_000, id: SourceIdentifier.freshRSSItem(accountID: old, itemID: "a1"))
        )
        context.insert(foreign)
        try context.save()

        let derived = AccountIdentity(record).accountID
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: makeKeychain())

        let expected = ScopeID.source(SourceIdentifier.freshRSS(accountID: derived, streamID: "feed/1"))
        #expect(foreign.scope == expected)

        let queued = try context.fetch(FetchDescriptor<PendingChange>())
            .filter { $0.collection == .position }
            .map(\.recordID)
        #expect(!queued.contains(PositionMark.key(scope: expected, deviceID: "device-B")))
    }

    /// The new ids have to reach the server, or the other device never learns them — and the
    /// records the old ids named have to go, or they sit there for ever naming rows nothing has.
    @Test("The rewritten records are queued, and the ones they replace are tombstoned")
    func queuesTheRewriteForSync() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try populate(context, accountID: old)

        let oldFeedScope = ScopeID.source(SourceIdentifier.freshRSS(accountID: old, streamID: "feed/1"))
        let oldItemID = SourceIdentifier.freshRSSItem(accountID: old, itemID: "a1")

        let derived = AccountIdentity(record).accountID
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: makeKeychain())

        let pending = try context.fetch(FetchDescriptor<PendingChange>())
        let newItemID = SourceIdentifier.freshRSSItem(accountID: derived, itemID: "a1")

        // The account under its derived id, so an unmigrated device converges on it.
        #expect(pending.contains { $0.collection == .account && $0.recordID == derived.uuidString && !$0.isDeletion })
        // The position under its new key, and the old key deleted.
        #expect(pending.contains {
            $0.collection == .position
                && $0.recordID == PositionMark.key(scope: .source(SourceIdentifier.freshRSS(accountID: derived, streamID: "feed/1")), deviceID: Self.device)
                && !$0.isDeletion
        })
        #expect(pending.contains {
            $0.collection == .position
                && $0.recordID == PositionMark.key(scope: oldFeedScope, deviceID: Self.device)
                && $0.isDeletion
        })
        // The saved item under its new id, and the copy that opened an empty pane deleted.
        #expect(pending.contains { $0.collection == .readLater && $0.recordID == newItemID && !$0.isDeletion })
        #expect(pending.contains { $0.collection == .readLater && $0.recordID == oldItemID && $0.isDeletion })
    }

    /// An account's secret is keyed by its id, so a rename that leaves it behind is a silent
    /// sign-out.
    @Test("The credential moves with the account")
    func movesTheCredential() async throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let keychain = makeKeychain()
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try context.save()
        try await keychain.setString("secret", for: .freshRSSAPIPassword, key: old.uuidString)

        let derived = AccountIdentity(record).accountID
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: keychain)

        #expect(try await keychain.string(for: .freshRSSAPIPassword, key: derived.uuidString) == "secret")
        #expect(try await keychain.string(for: .freshRSSAPIPassword, key: old.uuidString) == nil)
    }

    /// An account added on another device arrives with no credential at all. It still has to be
    /// re-keyed, or signing in to it later would store the secret under an id nothing points at.
    @Test("An account with no credential is migrated anyway")
    func migratesAccountsWithoutCredentials() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        let record = account(id: old)
        context.insert(record)
        try context.save()

        let derived = AccountIdentity(record).accountID
        let report = try AccountIDMigration.run(
            deviceID: Self.device,
            in: context,
            keychain: makeKeychain()
        )

        #expect(report.accounts == [old: derived])
        #expect(record.id == derived)
    }

    // MARK: - Doing nothing

    /// The ordinary launch. Every account already holds its derived id, so the pass stops at the
    /// account table and writes nothing — which is what lets it run unguarded on every launch.
    @Test("A migrated store is left alone")
    func isIdempotent() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let identity = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: "https://rss.example.net",
            username: "matze"
        )
        let record = account(id: identity.accountID)
        context.insert(record)
        try populate(context, accountID: identity.accountID)

        let report = try AccountIDMigration.run(
            deviceID: Self.device,
            in: context,
            keychain: makeKeychain()
        )

        #expect(!report.didRun)
        #expect(try context.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }

    /// Running it twice is the same as running it once — the second pass has nothing left to find.
    @Test("Running it again changes nothing")
    func secondPassIsANoOp() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let old = UUID()
        context.insert(account(id: old))
        try populate(context, accountID: old)

        let keychain = makeKeychain()
        try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: keychain)
        let second = try AccountIDMigration.run(deviceID: Self.device, in: context, keychain: keychain)

        #expect(!second.didRun)
    }

    /// Two rows for one account both want the same derived id, and renaming either onto it would
    /// break the model's uniqueness constraint. Left for `AccountDeduplication`, which knows which
    /// copy holds a credential.
    @Test("Duplicate accounts are left for deduplication")
    func leavesDuplicatesAlone() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let first = UUID()
        let second = UUID()
        context.insert(account(id: first))
        context.insert(account(id: second))
        try context.save()

        let report = try AccountIDMigration.run(
            deviceID: Self.device,
            in: context,
            keychain: makeKeychain()
        )

        #expect(!report.didRun)
        let ids = Set(try context.fetch(FetchDescriptor<AccountRecord>()).map(\.id))
        #expect(ids == [first, second])
    }
}
