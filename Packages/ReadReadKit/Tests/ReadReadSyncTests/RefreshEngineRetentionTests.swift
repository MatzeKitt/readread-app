import Foundation
import FreshRSSAPI
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// Retention's *gate* lives here, not in `RetentionService`: the service prunes whatever accounts
/// it is handed, and the decision about which accounts finished their walk is made by the engine.
/// Every `RetentionTests` case would still pass if that decision were wrong — and the app would be
/// deleting items behind interrupted runs.
@Suite("Refresh engine retention")
struct RefreshEngineRetentionTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
    private let loginBody = "SID=matze/tok\nAuth=matze/tok"

    /// Keeps one item per source, so a completed run over a handful of items prunes visibly.
    private let policy = RetentionPolicy(itemsPerSource: 1, maximumAge: 1)

    private func makeKeychain() -> KeychainStore {
        KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
    }

    private func makeAccount(in context: ModelContext, keychain: KeychainStore) throws {
        let account = AccountRecord(
            id: accountID,
            kind: .freshRSS,
            displayName: "Test FreshRSS",
            serverURLString: "https://rss.example.net",
            username: "matze"
        )
        context.insert(account)
        try context.save()
        try keychain.setString("p", for: .freshRSSAPIPassword, key: accountID.uuidString)
    }

    /// One page of items, old enough that the age rule cannot hold them back.
    private func page(count: Int, continuation: String?) -> StubTransport.Response {
        let items = (0..<count).map { offset -> String in
            let id = 1_000 - offset
            return """
            {
                "id": "tag:google.com,2005:reader/item/\(String(format: "%016llx", UInt64(id)))",
                "crawlTimeMsec": "1000000000000",
                "published": 1000000000,
                "title": "Item \(id)",
                "canonical": [{ "href": "https://example.com/\(id)" }],
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>Body.</p>" }
            }
            """
        }
        let field = continuation.map { ",\"continuation\":\"\($0)\"" } ?? ""
        return .json("{\"items\":[\(items.joined(separator: ","))]\(field)}")
    }

    private let subscriptions = StubTransport.Response.json(
        #"{"subscriptions":[{"id":"feed/1","title":"A Feed","categories":[],"iconUrl":""}]}"#
    )

    private func makeEngine(
        container: ModelContainer,
        transport: StubTransport,
        keychain: KeychainStore,
        retention: RetentionPolicy? = nil
    ) -> RefreshEngine {
        RefreshEngine(
            container: container,
            connections: AccountConnections(
                keychain: keychain,
                http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            // No token stored for this service, so the sync half is a no-op and cannot reach a
            // network. The badge is likewise inert — neither is what this suite is about.
            endpoint: SyncEndpoint(keychain: keychain),
            badge: BadgePublisher { _ in },
            retention: retention ?? policy
        )
    }

    private func itemCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<CachedItem>())
    }

    @Test("A completed run prunes the cache")
    func completedRunPrunes() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        try makeAccount(in: ModelContext(container), keychain: keychain)

        let transport = StubTransport([
            .text(loginBody),
            subscriptions,
            page(count: 5, continuation: nil),
        ])
        let engine = makeEngine(container: container, transport: transport, keychain: keychain)

        try await engine.perform(.freshRSSFeeds, trigger: .manual)

        // Five ingested, one kept: the walk finished, so the cache is safe to trim.
        #expect(try itemCount(in: container) == 1)
    }

    @Test("The fetch window setting reaches retention")
    func fetchWindowSettingReachesRetention() async throws {
        // A policy that on its own can delete nothing: a thousand kept per source and the age rule
        // switched off. Whatever goes, goes because the window setting arrived — which is the wire
        // this test exists for. The engine holds the window as state and the policy is injected at
        // construction, so it is easy to build this and forget to join the two.
        let inert = RetentionPolicy(itemsPerSource: 1000, maximumAge: 0)

        func run(windowDays: Int) async throws -> Int {
            let container = try ReadReadStore.inMemoryContainer()
            let keychain = makeKeychain()
            try makeAccount(in: ModelContext(container), keychain: keychain)

            let transport = StubTransport([
                .text(loginBody),
                subscriptions,
                page(count: 5, continuation: nil),
            ])
            let engine = makeEngine(
                container: container,
                transport: transport,
                keychain: keychain,
                retention: inert
            )
            await engine.setHistoryWindowDays(windowDays)
            try await engine.perform(.freshRSSFeeds, trigger: .manual)
            return try itemCount(in: container)
        }

        // The fixture publishes in 2001, so every item is outside any real window. All but the one
        // at the reading position go — that one is the fold itself and is never below a marker.
        #expect(try await run(windowDays: 1) == 1)
        #expect(try await run(windowDays: HistoryWindow.unlimited) == 5)
    }

    @Test("An interrupted run prunes nothing")
    func interruptedRunDoesNotPrune() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        try makeAccount(in: ModelContext(container), keychain: keychain)

        // The page reports a continuation and the next request fails, so the walk stops partway.
        let transport = StubTransport([
            .text(loginBody),
            subscriptions,
            page(count: 5, continuation: "next"),
            .status(500, body: "boom"),
        ])
        let engine = makeEngine(container: container, transport: transport, keychain: keychain)

        _ = try? await engine.perform(.freshRSSFeeds, trigger: .manual)

        // The items are still there. Pruning here would evict exactly what the resumed run is
        // about to re-fetch, and then evict it again on the next attempt.
        #expect(try itemCount(in: container) == 5)
    }

    @Test("An account with no stored credential does not fail the refresh")
    func credentiallessAccountDoesNotFailTheRefresh() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        let context = ModelContext(container)

        // One account that can sign in, and a second copy of it that cannot — the state a device
        // ends up in once the account list has synced from another device.
        try makeAccount(in: context, keychain: keychain)
        context.insert(AccountRecord(
            id: UUID(),
            kind: .freshRSS,
            displayName: "Test FreshRSS (copy)",
            serverURLString: "https://rss.example.net",
            username: "matze"
        ))
        try context.save()

        // No new items: the ordinary case for a refresh, and the term that made this fail *every*
        // cycle rather than occasionally.
        let transport = StubTransport([
            .text(loginBody),
            subscriptions,
            page(count: 0, continuation: nil),
        ])
        let engine = makeEngine(container: container, transport: transport, keychain: keychain)

        // Must not throw. Throwing is what earns the coordinator's exponential backoff, and a
        // credential that will never arrive by waiting took every healthy account off the network
        // with it — the app made no requests at all for minutes at a time.
        try await engine.perform(.freshRSSFeeds, trigger: .manual)
    }

    @Test("A reachable server that errors still fails the refresh")
    func serverErrorStillFailsTheRefresh() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        try makeAccount(in: ModelContext(container), keychain: keychain)

        // The counterpart: this one *is* worth backing off from, and narrowing the throw must not
        // have made every failure silent.
        let transport = StubTransport([.text(loginBody), .status(500, body: "boom")])
        let engine = makeEngine(container: container, transport: transport, keychain: keychain)

        await #expect(throws: (any Error).self) {
            try await engine.perform(.freshRSSFeeds, trigger: .manual)
        }
    }

    @Test("An account whose server is unreachable is not pruned")
    func failedAccountIsNotPruned() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = makeKeychain()
        let context = ModelContext(container)
        try makeAccount(in: context, keychain: keychain)

        // Items already in the cache from an earlier, successful run.
        let sourceID = SourceIdentifier.freshRSS(accountID: accountID, streamID: "feed/1")
        context.insert(CachedSource(id: sourceID, accountID: accountID, kind: .article, title: "A Feed"))
        for index in 0..<5 {
            let key = SortKey(millis: 1_000_000_000_000 + Int64(index), id: "old-\(index)")
            context.insert(CachedItem(
                id: "old-\(index)",
                sourceID: sourceID,
                accountID: accountID,
                kind: .article,
                title: "Old \(index)",
                publishedAt: Date(millisecondsSinceEpoch: 1_000_000_000_000),
                sortKey: key,
                ingestKey: key
            ))
        }
        try context.save()

        let transport = StubTransport([.text(loginBody), .status(503, body: "down")])
        let engine = makeEngine(container: container, transport: transport, keychain: keychain)

        _ = try? await engine.perform(.freshRSSFeeds, trigger: .manual)

        // A server being down is not a licence to delete the copy that is keeping the app usable
        // offline — which is precisely when it matters most.
        #expect(try itemCount(in: container) == 5)
    }
}


/// The badge's *other* trigger. `BadgePublisherTests` pins when a count may be published;
/// this pins that a settled scroll actually reaches it, which is a wire between three actors
/// and the one part that a unit test of either end would miss.
@Suite("Refresh engine badge")
struct RefreshEngineBadgeTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!
    private let loginBody = "SID=matze/tok\nAuth=matze/tok"
    private let deviceID = "device-a"

    private actor Recorder {
        private(set) var writes: [Int] = []
        nonisolated func setter() -> BadgePublisher.Setter {
            { [weak self] count in await self?.record(count) }
        }
        private func record(_ count: Int) { writes.append(count) }
    }

    private func page(count: Int) -> StubTransport.Response {
        let items = (0..<count).map { offset -> String in
            let id = 1_000 - offset
            return """
            {
                "id": "tag:google.com,2005:reader/item/\(String(format: "%016llx", UInt64(id)))",
                "crawlTimeMsec": "\(1_700_000_000_000 + id)",
                "published": \(1_700_000_000 + id),
                "title": "Item \(id)",
                "origin": { "streamId": "feed/1" },
                "summary": { "content": "<p>Body.</p>" }
            }
            """
        }
        return .json("{\"items\":[\(items.joined(separator: ","))]}")
    }

    @Test("A settled scroll republishes the badge")
    func settledScrollRepublishes() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let keychain = KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
        let context = ModelContext(container)
        context.insert(AccountRecord(
            id: accountID,
            kind: .freshRSS,
            displayName: "Test FreshRSS",
            serverURLString: "https://rss.example.net",
            username: "matze"
        ))
        try context.save()
        try await keychain.setString("p", for: .freshRSSAPIPassword, key: accountID.uuidString)

        let recorder = Recorder()
        let engine = RefreshEngine(
            container: container,
            connections: AccountConnections(
                keychain: keychain,
                http: HTTPClient(transport: StubTransport([
                    .text(loginBody),
                    .json(#"{"subscriptions":[{"id":"feed/1","title":"A Feed","categories":[],"iconUrl":""}]}"#),
                    page(count: 5),
                ]), policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            endpoint: SyncEndpoint(keychain: keychain),
            badge: BadgePublisher(setBadge: recorder.setter()),
            // Nothing may be pruned, so the only thing moving the count is the position.
            retention: RetentionPolicy(itemsPerSource: 1000, maximumAge: 0)
        )

        // The fixture's items are years old, and the engine hands its own window to retention —
        // so without this the completed run prunes them all and there is nothing to scroll.
        await engine.setHistoryWindowDays(HistoryWindow.unlimited)

        // A completed run establishes the baseline. Ingest seeds the marker at the newest item,
        // so the count starts at zero.
        try await engine.perform(.freshRSSFeeds, trigger: .manual)
        #expect(await recorder.writes == [0])

        // Scroll back through three items, the way the fold commit does.
        let verify = ModelContext(container)
        let items = try verify.fetch(FetchDescriptor<CachedItem>(
            sortBy: [SortDescriptor(\.sortKeyRaw, order: .reverse)]
        ))
        try ThresholdService.setPositionCascading(
            .all,
            to: items[3].sortKey,
            deviceID: deviceID,
            in: verify
        )
        try verify.save()

        await engine.publishBadgeForPositionChange()

        #expect(await recorder.writes == [0, 3])
    }
}
