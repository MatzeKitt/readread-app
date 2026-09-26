import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

@Suite("SyncCoordinator")
struct SyncCoordinatorTests {

    private func makeCoordinator(
        _ transport: StubTransport,
        maxPages: Int = 20
    ) throws -> (SyncCoordinator, SyncStore, ModelContainer) {
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: "https://sync.example.net")!, token: "t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        return (SyncCoordinator(client: client, store: store, maxPagesPerRun: maxPages), store, container)
    }

    private func positionPayload(device: String, millis: Int64) throws -> String {
        try SyncPayloadCoding.encodeToString(PositionPayload(
            scope: "all",
            deviceID: device,
            markSortKey: SortKey(millis: millis, id: "i").rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(millis))
        ))
    }

    private func pullPage(_ records: String, maxRevision: Int, hasMore: Bool) -> StubTransport.Response {
        .json(#"{"records":[\#(records)],"maxRevision":\#(maxRevision),"hasMore":\#(hasMore)}"#)
    }

    private func record(device: String, millis: Int64, revision: Int) throws -> String {
        let payload = try positionPayload(device: device, millis: millis)
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"collection":"position","id":"all|\#(device)","revision":\#(revision),"deleted":false,"updatedAt":\#(revision),"payload":"\#(payload)"}"#
    }

    // MARK: - Ordering

    /// Pull before push, so a local change is merged against the newest server state before being
    /// sent rather than landing on top of a state this device has never seen.
    @Test("A run pulls before it pushes")
    func pullsBeforePushing() async throws {
        let transport = StubTransport([
            pullPage(try record(device: "iphone", millis: 5_000, revision: 1), maxRevision: 1, hasMore: false),
            .json(#"{"applied":[{"collection":"position","id":"all|mac","revision":2}],"maxRevision":2}"#),
        ])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(collection: .position, recordID: "all|mac", payload: try positionPayload(device: "mac", millis: 9_000))

        let outcome = try await coordinator.sync()

        #expect(outcome.pulledRecords == 1)
        #expect(outcome.pushedRecords == 1)
        #expect(await transport.requests[0].httpMethod == "GET")
        #expect(await transport.requests[1].httpMethod == "POST")
    }

    @Test("With nothing queued, a run only pulls")
    func nothingQueuedMeansNoPush() async throws {
        let transport = StubTransport([pullPage("", maxRevision: 0, hasMore: false)])
        let (coordinator, _, _) = try makeCoordinator(transport)

        let outcome = try await coordinator.sync()

        #expect(outcome.pushedRecords == 0)
        #expect(await transport.requestCount == 1)
    }

    // MARK: - Leaving the app

    /// The way out. A settled fold is queued in the same transaction as the position itself and
    /// pushed on a two-second debounce — which is right for a reader who is scrolling and does not
    /// survive one who is quitting.
    @Test("A push on the way out sends what is queued without pulling")
    func pushPendingSkipsThePull() async throws {
        let transport = StubTransport([
            .json(#"{"applied":[{"collection":"position","id":"all|mac","revision":2}],"maxRevision":2}"#),
        ])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(
            collection: .position,
            recordID: "all|mac",
            payload: try positionPayload(device: "mac", millis: 9_000)
        )

        #expect(try await coordinator.pushPending() == 1)

        // One request, and it is the push: no page was fetched on the way out.
        #expect(await transport.requestCount == 1)
        #expect(await transport.requests[0].httpMethod == "POST")
        #expect(try await store.pendingPushRecords().isEmpty)
    }

    /// Nothing queued is the ordinary case — the debounce usually got there first — and it must
    /// not cost a request at the moment the app is trying to exit.
    @Test("A push on the way out with nothing queued sends nothing")
    func pushPendingWithEmptyOutbox() async throws {
        let transport = StubTransport([])
        let (coordinator, _, _) = try makeCoordinator(transport)

        #expect(try await coordinator.pushPending() == 0)
        #expect(await transport.requestCount == 0)
    }

    /// A failure leaves the record where it was. The next launch pulls and pushes it, which is
    /// where it would have been without any of this — so the way out can afford to be silent.
    @Test("A failed push on the way out keeps the record queued")
    func failedPushPendingKeepsTheRecord() async throws {
        let transport = StubTransport([.status(500)])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(
            collection: .position,
            recordID: "all|mac",
            payload: try positionPayload(device: "mac", millis: 9_000)
        )

        await #expect(throws: (any Error).self) { try await coordinator.pushPending() }
        #expect(try await store.pendingPushRecords().count == 1)
    }

    // MARK: - Paging

    @Test("A run follows hasMore across pages")
    func followsPagination() async throws {
        let transport = StubTransport([
            pullPage(try record(device: "a", millis: 1_000, revision: 1), maxRevision: 1, hasMore: true),
            pullPage(try record(device: "b", millis: 2_000, revision: 2), maxRevision: 2, hasMore: true),
            pullPage(try record(device: "c", millis: 3_000, revision: 3), maxRevision: 3, hasMore: false),
        ])
        let (coordinator, store, container) = try makeCoordinator(transport)

        let outcome = try await coordinator.sync()

        #expect(outcome.pagesPulled == 3)
        #expect(outcome.appliedRecords == 3)
        #expect(outcome.isComplete)
        #expect(try await store.pullCursor() == 3)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PositionMark>()) == 3)
    }

    @Test("Each page is requested from the previous page's cursor")
    func advancesCursorBetweenPages() async throws {
        let transport = StubTransport([
            pullPage(try record(device: "a", millis: 1_000, revision: 4), maxRevision: 4, hasMore: true),
            pullPage(try record(device: "b", millis: 2_000, revision: 9), maxRevision: 9, hasMore: false),
        ])
        let (coordinator, _, _) = try makeCoordinator(transport)

        _ = try await coordinator.sync()

        #expect(await transport.queryItems(at: 0)["since"] == "0")
        #expect(await transport.queryItems(at: 1)["since"] == "4")
    }

    @Test("A run stops at its page budget without claiming completion")
    func stopsAtPageBudget() async throws {
        // Revisions must advance across pages, or the anti-loop guard below stops the run first
        // and the budget is never reached.
        let pages = try (1...6).map { revision in
            pullPage(
                try record(device: "d\(revision)", millis: Int64(revision) * 1_000, revision: revision),
                maxRevision: revision,
                hasMore: true
            )
        }
        let transport = StubTransport(pages)
        let (coordinator, _, _) = try makeCoordinator(transport, maxPages: 3)

        let outcome = try await coordinator.sync()

        #expect(outcome.pagesPulled == 3)
        #expect(outcome.isComplete == false)
    }

    /// A server that claims more pages but never advances the cursor would loop forever. Stopping
    /// is the safe response — the next run retries from the same place.
    @Test("A page claiming more but not advancing the cursor ends the run")
    func nonAdvancingPageEndsRun() async throws {
        let transport = StubTransport([], fallback: pullPage("", maxRevision: 0, hasMore: true))
        let (coordinator, _, _) = try makeCoordinator(transport, maxPages: 50)

        let outcome = try await coordinator.sync()

        #expect(outcome.pagesPulled == 1)
        #expect(outcome.isComplete == false)
    }

    // MARK: - The push-cursor rule

    /// The most important rule in the design. Another device may hold a revision below the push
    /// response's `maxRevision` that this device has not pulled; adopting it would skip that
    /// change permanently and silently.
    @Test("The pull cursor is never taken from a push response")
    func pushDoesNotAdvancePullCursor() async throws {
        let transport = StubTransport([
            pullPage("", maxRevision: 2, hasMore: false),
            // The server is at 99 — mostly other devices' writes this one has not seen.
            .json(#"{"applied":[{"collection":"filter","id":"f1","revision":99}],"maxRevision":99}"#),
        ])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        _ = try await coordinator.sync()

        // Still the pull's value. At 99 the next pull would skip revisions 3 through 98.
        #expect(try await store.pullCursor() == 2)
    }

    // MARK: - Single-flight

    /// Two concurrent runs would both drain the same outbox and push every record twice.
    @Test("Concurrent syncs collapse into one run")
    func concurrentSyncsCollapse() async throws {
        let transport = StubTransport([pullPage("", maxRevision: 1, hasMore: false)])
        let (coordinator, _, _) = try makeCoordinator(transport)

        let outcomes = try await withThrowingTaskGroup(of: SyncOutcome.self) { group in
            for _ in 0..<8 {
                group.addTask { try await coordinator.sync() }
            }
            var collected: [SyncOutcome] = []
            for try await outcome in group { collected.append(outcome) }
            return collected
        }

        #expect(outcomes.count == 8)
        #expect(await transport.requestCount == 1)
    }

    // MARK: - Failures

    @Test("A rejected push drops the record and surfaces the error")
    func rejectedPushDropsRecord() async throws {
        let transport = StubTransport([
            pullPage("", maxRevision: 0, hasMore: false),
            .status(400, body: #"{"error":"bad_request","message":"Unknown collection"}"#),
        ])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        await #expect(throws: SyncError.rejected("Unknown collection")) {
            _ = try await coordinator.sync()
        }
        // Dropped, not retried: it would fail identically forever and block everything behind it.
        #expect(try await store.pendingPushRecords().isEmpty)
    }

    @Test("A server error keeps the record queued for the next run")
    func serverErrorKeepsRecordQueued() async throws {
        let transport = StubTransport([
            pullPage("", maxRevision: 0, hasMore: false),
            .status(500, body: "boom"),
        ])
        let (coordinator, store, _) = try makeCoordinator(transport)
        try await store.enqueue(collection: .filter, recordID: "f1", payload: "{}")

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.sync()
        }
        #expect(try await store.pendingPushRecords().count == 1)
    }

    @Test("A failure is recorded for the settings screen and cleared on the next success")
    func failureIsRecordedThenCleared() async throws {
        let transport = StubTransport([.status(500, body: "boom")], fallback: pullPage("", maxRevision: 1, hasMore: false))
        let (coordinator, _, container) = try makeCoordinator(transport)

        _ = try? await coordinator.sync()
        var state = try ModelContext(container).fetch(FetchDescriptor<SyncState>())
        #expect(state.first?.lastErrorDescription != nil)

        _ = try await coordinator.sync()
        state = try ModelContext(container).fetch(FetchDescriptor<SyncState>())
        #expect(state.first?.lastErrorDescription == nil)
    }

    @Test("An unauthorized pull surfaces as such")
    func unauthorizedIsTyped() async throws {
        let transport = StubTransport([.status(401, body: "")])
        let (coordinator, _, _) = try makeCoordinator(transport)

        await #expect(throws: SyncError.unauthorized) {
            _ = try await coordinator.sync()
        }
    }

    // MARK: - Accounts removed elsewhere

    @Test("An account removed on another device has its credential forgotten here")
    func removedAccountLosesItsCredential() async throws {
        let keychain = KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
        let id = UUID()
        try await keychain.setString("token", for: .mastodonAccessToken, key: id.uuidString)

        let account = AccountRecord(
            id: id,
            kind: .mastodon,
            displayName: "@matze@mastodon.social",
            serverURLString: "https://mastodon.social",
            username: "matze"
        )
        let payload = try SyncPayloadCoding.encodeToString(AccountPayload(account))
            .replacingOccurrences(of: "\"", with: "\\\"")
        let tombstone = #"{"collection":"account","id":"\#(id.uuidString)","revision":1,"deleted":true,"updatedAt":1,"payload":"\#(payload)"}"#

        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        context.insert(account)
        try context.save()

        let transport = StubTransport([pullPage(tombstone, maxRevision: 1, hasMore: false)])
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: "https://sync.example.net")!, token: "t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        let coordinator = SyncCoordinator(
            client: client,
            store: SyncStore(modelContainer: container),
            connections: AccountConnections(keychain: keychain)
        )

        let outcome = try await coordinator.sync()

        // Removing the row is not the whole job. The token is keyed by the account id, so leaving it
        // behind means a credential for an account nothing can name any more, sitting in the
        // Keychain until the device is wiped.
        #expect(outcome.removedAccountIDs == [id])
        #expect(try await keychain.string(for: .mastodonAccessToken, key: id.uuidString) == nil)
    }
}
