import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// Opening an existing store with the current schema.
///
/// The app declares no `SchemaMigrationPlan`, so every schema change so far has relied on
/// SwiftData's implicit lightweight migration — which is fine for additive changes and silently
/// catastrophic when it is not: the container throws at launch and the app cannot start, or worse
/// it opens onto an empty store. That risk lands on data the user cannot get back. Reading
/// positions, Read Later and filter rules are the app's *only* irreplaceable state; everything
/// else can be re-fetched.
///
/// So this writes a store in the old shape and opens it with the live schema, in the same process,
/// the way an update does.
@Suite("Migration")
struct MigrationTests {

    private let accountID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
    private let ruleID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000002")!

    /// A temporary store URL that is cleaned up with the test.
    private func makeStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "readread-migration-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Copies the recorded legacy store to a scratch path and returns it.
    ///
    /// A recorded file rather than one written here at runtime: creating a `ModelContainer` for
    /// the old schema puts two definitions of the entity `CachedSource` in one process, and with
    /// tests running in parallel that aborts the whole run. See `LegacySchema` for the exception
    /// it throws. A binary fixture is also the more honest test — it is a store an older build
    /// actually wrote, not one this build reconstructed.
    private func makeLegacyStore() throws -> URL {
        let bundled = try #require(
            Bundle.module.url(forResource: "legacy-v1", withExtension: "store", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "legacy-v1", withExtension: "store")
        )
        let url = makeStoreURL()
        try FileManager.default.copyItem(at: bundled, to: url)
        return url
    }

    @Test("A store written by the previous schema still opens")
    func legacyStoreOpens() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        // The whole test in one line: if implicit migration cannot handle the change, this throws
        // and the app would not launch.
        let container = try ReadReadStore.container(url: url)
        let context = ModelContext(container)

        #expect(try context.fetchCount(FetchDescriptor<CachedItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CachedSource>()) == 1)
    }

    @Test("The reading position survives")
    func positionSurvives() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        let context = ModelContext(try ReadReadStore.container(url: url))
        let position = try ThresholdService.effectivePosition(for: .all, in: context)

        // The one piece of state the app exists to keep. Losing it silently resets the user to the
        // top of every feed, which looks like the app forgetting everything they had read.
        #expect(position.markSortKey == SortKey(millis: 1_700_000_000_000, id: "item-1"))
    }

    @Test("Read Later, filters and accounts survive")
    func syncedStateSurvives() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        let context = ModelContext(try ReadReadStore.container(url: url))

        let saved = try #require(try ReadLaterService.entry(for: "freshrss:acct:item-1", in: context))
        // Including the offline snapshot: an entry whose archive was dropped still looks present
        // in the list, and only fails when it is opened.
        #expect(saved.archivedHTML == "<p>Kept offline.</p>")

        let rule = try #require(try context.fetch(FetchDescriptor<FilterRule>()).first)
        #expect(rule.id == ruleID)
        #expect(rule.pattern == "football")
        #expect(rule.fields == .title)
        #expect(rule.scope == .everywhere)

        let account = try #require(try context.fetch(FetchDescriptor<AccountRecord>()).first)
        #expect(account.id == accountID)
        #expect(account.kind == .freshRSS)
        // The Keychain is keyed by this id: a changed account id is a signed-out account.
        #expect(account.serverURL?.host() == "rss.example.com")
    }

    @Test("Properties added since take their defaults rather than failing")
    func newPropertiesTakeDefaults() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        let context = ModelContext(try ReadReadStore.container(url: url))
        let item = try #require(try context.fetch(FetchDescriptor<CachedItem>()).first)
        let source = try #require(try context.fetch(FetchDescriptor<CachedSource>()).first)

        #expect(item.replyCount == 0)
        #expect(item.reblogCount == 0)
        #expect(item.favouriteCount == 0)
        #expect(item.inReplyToStatusID == nil)
        #expect(item.fullPageHTML == nil)
        // Nil rather than a date: "fetched and found nothing" must not be the state a migrated
        // item starts in, or its page would never be fetched at all.
        #expect(item.fullPageFetchedAt == nil)

        // Off, not on: turning full-page loading on for every existing feed would start a request
        // per item opened, silently, on the strength of an update. Comments are two requests per
        // item on the same reasoning, against the publisher's server rather than the user's own.
        #expect(!source.loadsFullPageContent)
        #expect(!source.loadsComments)

        // Nil, and each nil means "nobody has looked yet" rather than "no". `StatusBackfill` is
        // what turns them into answers, and it finds these rows precisely *because* they are nil —
        // a migration that filled them with `false` would hide every existing post from it and the
        // link previews and Like state would never appear on anything already in the store.
        #expect(item.cardURLString == nil)
        #expect(item.linkCard == nil)
        #expect(item.isFavourited == nil)
        #expect(item.isReblogged == nil)

        // The one whose Swift default is `true`, which is the interesting case: a Swift property
        // initialiser is not the same thing as a CoreData attribute default, and if migration
        // fills a new `Bool` column with `false` then every item in an existing store is hidden
        // from every list and count the moment the user updates. Nothing else here would notice —
        // the app would simply come up empty.
        #expect(item.isAccountEnabled)
    }

    @Test("Entities the old store never had are created empty")
    func newEntitiesAppear() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        let context = ModelContext(try ReadReadStore.container(url: url))

        // `SyncCursor`, `PendingChange` and `SyncState` are absent from the legacy schema entirely.
        // Adding a whole entity is the change most likely to need a real migration plan, so it is
        // worth knowing it does not.
        #expect(try context.fetchCount(FetchDescriptor<SyncCursor>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingChange>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SyncState>()) == 0)
    }

    @Test("The migrated store is writable, not just readable")
    func migratedStoreAcceptsWrites() throws {
        let url = try makeLegacyStore()
        defer { removeStore(at: url) }

        let context = ModelContext(try ReadReadStore.container(url: url))

        // A migration that leaves the store read-only, or leaves an index in a state the new
        // constraints reject, only shows up on the first write — which in the app is a scroll.
        _ = try ThresholdService.setPosition(
            .all,
            to: SortKey(millis: 1_800_000_000_000, id: "item-2"),
            deviceID: "device-a",
            in: context
        )
        try context.save()

        let reopened = ModelContext(try ReadReadStore.container(url: url))
        #expect(try ThresholdService.effectivePosition(for: .all, in: reopened).markSortKey
            == SortKey(millis: 1_800_000_000_000, id: "item-2"))
    }
}
