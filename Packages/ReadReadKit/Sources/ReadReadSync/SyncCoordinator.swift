import Foundation
import ReadReadModel
import ReadReadSupport

/// What one sync run did.
public struct SyncOutcome: Sendable, Equatable {

    public var pulledRecords: Int
    public var appliedRecords: Int
    public var pushedRecords: Int
    public var pagesPulled: Int

    /// Whether the pull reached the end of the server's changes.
    public var isComplete: Bool

    /// Which collections the pull actually changed locally.
    ///
    /// Reported because applying a record is not always the end of the work: a pulled filter rule
    /// has to be re-applied across the cache before it hides anything, and only the caller has
    /// somewhere to run that.
    public var changedCollections: Set<SyncCollection>

    /// Accounts this run removed because another device removed them.
    ///
    /// Their Keychain items have already been forgotten by the time this is returned — that is the
    /// run's own doing, not a job left for the caller. It is reported because it is the one account
    /// change that is not undoable and not visible in a diff of the list: naming the ids is what
    /// makes it assertable, and what gives a caller somewhere to hang a "signed out of N accounts"
    /// notice if one is ever wanted.
    public var removedAccountIDs: Set<UUID>

    public init(
        pulledRecords: Int = 0,
        appliedRecords: Int = 0,
        pushedRecords: Int = 0,
        pagesPulled: Int = 0,
        isComplete: Bool = false,
        changedCollections: Set<SyncCollection> = [],
        removedAccountIDs: Set<UUID> = []
    ) {
        self.pulledRecords = pulledRecords
        self.appliedRecords = appliedRecords
        self.pushedRecords = pushedRecords
        self.pagesPulled = pagesPulled
        self.isComplete = isComplete
        self.changedCollections = changedCollections
        self.removedAccountIDs = removedAccountIDs
    }
}

/// Runs sync: pull, then push.
///
/// An actor holding one in-flight task, so a timer tick during a manual sync joins the running run
/// instead of starting a second one. Two concurrent runs would both drain the same outbox and push
/// the same records twice.
public actor SyncCoordinator {

    private let client: SyncClient
    private let store: SyncStore

    /// Maximum pages one run will pull, so a device returning after a long absence drains across
    /// several runs rather than holding a single request open indefinitely.
    private let maxPagesPerRun: Int

    /// Where an account removed by sync has its credentials forgotten.
    ///
    /// Here rather than in `SyncStore` because the store is a `@ModelActor` over the SwiftData
    /// container and has no business holding the Keychain, and because injecting it is what lets a
    /// test watch the purge happen without touching the real one.
    private let connections: AccountConnections

    private var inFlight: Task<SyncOutcome, any Error>?

    public init(
        client: SyncClient,
        store: SyncStore,
        maxPagesPerRun: Int = 20,
        connections: AccountConnections = AccountConnections()
    ) {
        self.client = client
        self.store = store
        self.maxPagesPerRun = maxPagesPerRun
        self.connections = connections
    }

    /// Runs a sync, joining one already in progress.
    public func sync() async throws -> SyncOutcome {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<SyncOutcome, any Error> { [client, store, maxPagesPerRun, connections] in
            try await Self.run(
                client: client,
                store: store,
                maxPages: maxPagesPerRun,
                connections: connections
            )
        }
        inFlight = task
        defer { inFlight = nil }

        do {
            return try await task.value
        } catch {
            try? await store.recordFailure(String(describing: error))
            throw error
        }
    }

    /// Pull first, then push.
    ///
    /// This order is deliberate. Pulling first means a local change is merged against the newest
    /// server state before being sent, so the outbox is never pushing on top of a state it has not
    /// seen. It also means a conflicting remote change is visible to the user before their own
    /// edit overwrites it.
    private static func run(
        client: SyncClient,
        store: SyncStore,
        maxPages: Int,
        connections: AccountConnections
    ) async throws -> SyncOutcome {
        var outcome = SyncOutcome()

        // MARK: Pull
        var cursor = try await store.pullCursor()
        var isComplete = false

        for _ in 0..<maxPages {
            try Task.checkCancellation()

            let page = try await client.pull(since: cursor)
            outcome.pagesPulled += 1
            outcome.pulledRecords += page.records.count
            let result = try await store.applyReportingCollections(page)
            outcome.appliedRecords += result.applied
            outcome.changedCollections.formUnion(result.collections)
            outcome.removedAccountIDs.formUnion(result.removedAccountIDs)

            // An account removed on another device leaves its password or OAuth token here, keyed
            // by an id nothing names any more. Forgotten as the page is applied rather than at the
            // end of the run, so a run that fails half way through has still cleaned up what it
            // actually deleted.
            for id in result.removedAccountIDs {
                try? await connections.forgetCredentials(forAccountID: id)
            }

            // Read the cursor back from the store rather than trusting the page: `apply` advances
            // it monotonically, so this cannot go backwards even if a server replied oddly.
            let advanced = try await store.pullCursor()

            if !page.hasMore {
                isComplete = true
                break
            }
            // A page that claims more but does not move the cursor would loop forever. Stopping is
            // the safe response: the next run retries from the same place.
            guard advanced > cursor else {
                isComplete = false
                break
            }
            cursor = advanced
        }
        outcome.isComplete = isComplete

        // MARK: Push
        let pending = try await store.pendingPushRecords()
        guard !pending.isEmpty else { return outcome }

        do {
            _ = try await client.push(pending)
            try await store.clearPending(pending)
            outcome.pushedRecords = pending.count
        } catch let error as SyncError {
            // A rejection is permanent — the record is malformed and will fail identically forever,
            // so it is dropped rather than left to block everything queued behind it.
            if case .rejected = error {
                try await store.failPending(pending, permanent: true)
            } else {
                try await store.failPending(pending, permanent: false)
            }
            throw error
        } catch {
            try await store.failPending(pending, permanent: false)
            throw error
        }

        // Note: the push response's `maxRevision` is deliberately *not* stored as the pull cursor.
        // Another device may hold a lower revision this device has not pulled, and adopting it
        // would skip that change permanently.
        return outcome
    }
}
