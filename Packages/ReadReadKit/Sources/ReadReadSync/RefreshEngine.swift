import Foundation
import FreshRSSAPI
import MastodonAPI
import ReadReadModel
import ReadReadSupport
import SwiftData

/// What one refresh did, for the settings screen and the status line.
public struct RefreshReport: Sendable, Equatable {

    public var kind: RefreshKind
    public var itemsWritten: Int
    public var lateArrivals: Int

    /// Whether every account of this kind finished its walk.
    ///
    /// The badge only publishes on a complete run — a partial ingest under-counts, and a badge
    /// reading "3" while forty items wait is wrong in the worst direction.
    public var isComplete: Bool

    /// Accounts that failed, described for display. Never carries a credential.
    public var failures: [String]

    /// The subset of ``failures`` that retrying could actually fix.
    ///
    /// A server that is down, a timeout, a 500 — those are worth backing off from and trying
    /// again. An account with no stored credential or an unparseable address is not: it is a
    /// standing configuration problem, and retrying it on a doubling delay achieves nothing except
    /// dragging every healthy account into the same backoff. Both kinds still appear in
    /// ``failures``, because the user needs to see either one.
    public var retryableFailures: [String]

    public init(
        kind: RefreshKind,
        itemsWritten: Int = 0,
        lateArrivals: Int = 0,
        isComplete: Bool = true,
        failures: [String] = [],
        retryableFailures: [String]? = nil
    ) {
        self.kind = kind
        self.itemsWritten = itemsWritten
        self.lateArrivals = lateArrivals
        self.isComplete = isComplete
        self.failures = failures
        // Defaulting to *all* failures keeps every existing caller — and every test — behaving as
        // it did; only the account-connection path below narrows it.
        self.retryableFailures = retryableFailures ?? failures
    }
}

/// Performs a refresh: ingest the accounts of one kind, sync, then publish the badge.
///
/// This is the implementation `RefreshCoordinator` schedules. The split is worth stating: the
/// coordinator owns *when* work runs — cadence, single-flight, backoff, pausing — and knows nothing
/// about feeds; this owns *what* the work is and knows nothing about timers. Each is testable
/// without the other, which is why the scheduling policy could be pinned down long before there
/// was a server to talk to.
public actor RefreshEngine {

    private let container: ModelContainer
    private let connections: AccountConnections
    private let syncClient: SyncClient
    private let syncCoordinator: SyncCoordinator
    private let badge: BadgePublisher
    private let endpoint: SyncEndpoint

    /// How much of the item cache to keep. Injected so a test can prune with a policy small
    /// enough to reason about instead of writing a thousand fixtures.
    private let retention: RetentionPolicy

    /// Reports each finished refresh. Set by the app so the UI can show progress and failures.
    private var onReport: (@Sendable (RefreshReport) -> Void)?

    /// Reports a kind starting and finishing, so the UI can show that something is happening.
    ///
    /// Separate from `onReport`, which only fires for an ingest that produced a report — a sync
    /// tick produces none, and a spinner that only appears for feed refreshes would leave a manual
    /// ⌘R looking like it did nothing.
    private var onActivity: (@Sendable (RefreshKind, Bool) -> Void)?

    /// The scope whose count the badge shows, kept in step with the settings screen.
    private var badgeScope: ScopeID = .all

    /// How far back a refresh fetches, kept in step with the settings screen. `0` is everything.
    private var historyWindowDays: Int = HistoryWindow.default

    /// How many item-fetching runs are in flight.
    ///
    /// Read only by ``publishBadgeForPositionChange()``, to stay out of the way while a walk is
    /// landing pages: mid-run the store holds part of an item set, which is the one thing the
    /// badge's gate exists to keep off the icon. The run publishes for itself when it finishes,
    /// so skipping here loses nothing.
    private var ingestsInFlight = 0

    public init(
        container: ModelContainer,
        connections: AccountConnections = AccountConnections(),
        endpoint: SyncEndpoint = SyncEndpoint(),
        syncClient: SyncClient? = nil,
        badge: BadgePublisher,
        retention: RetentionPolicy = .default
    ) {
        self.container = container
        self.retention = retention
        self.connections = connections
        self.endpoint = endpoint

        let client = syncClient ?? SyncClient()
        self.syncClient = client
        syncCoordinator = SyncCoordinator(
            client: client,
            store: SyncStore(modelContainer: container)
        )
        self.badge = badge
    }

    public func setReportHandler(_ handler: @escaping @Sendable (RefreshReport) -> Void) {
        onReport = handler
    }

    public func setActivityHandler(_ handler: @escaping @Sendable (RefreshKind, Bool) -> Void) {
        onActivity = handler
    }

    public func setBadgeScope(_ scope: ScopeID) {
        badgeScope = scope
    }

    public func setHistoryWindowDays(_ days: Int) {
        historyWindowDays = max(0, days)
    }

    /// Re-reads the endpoint configuration, after it has been edited in Settings.
    public func reloadSyncConfiguration() async {
        await syncClient.configure(endpoint.configuration())
    }

    /// The closure to hand `RefreshCoordinator`.
    ///
    /// Returned rather than having the coordinator hold this actor, so the dependency runs one way:
    /// scheduling knows about work, work knows nothing about scheduling.
    public nonisolated func operation() -> RefreshCoordinator.Operation {
        { [weak self] kind, trigger in
            guard let self else { return }
            try await perform(kind, trigger: trigger)
        }
    }

    // MARK: - Performing

    public func perform(_ kind: RefreshKind, trigger: RefreshTrigger) async throws {
        onActivity?(kind, true)
        // `defer` rather than a call on each path, so a thrown error still clears the spinner —
        // a refresh that fails and leaves the UI spinning forever is worse than the failure.
        defer { onActivity?(kind, false) }

        switch kind {
        case .syncState:
            try await runSync()
        case .freshRSSFeeds, .mastodonFeeds:
            try await runIngest(kind, trigger: trigger)
        }
    }

    private func runSync() async throws {
        // Read once, and off this actor: building a configuration reads the bearer token from the
        // Keychain, which can block until the user answers a SecurityAgent prompt.
        let configuration = await endpoint.configuration()
        await syncClient.configure(configuration)
        guard configuration != nil else {
            // Not configured is not a failure. Throwing here would drive the coordinator's backoff
            // and fill the settings screen with errors for a feature the user has not set up.
            return
        }
        let outcome = try await syncCoordinator.sync()
        try await applyPulledSideEffects(outcome)
    }

    /// Finishes the work a pull started but could not complete on its own.
    ///
    /// Applying a record and *acting* on it are two different things for two of the collections,
    /// and both were missing — the records arrived and had no visible effect, which reads as sync
    /// being broken rather than as a step being skipped:
    ///
    /// - A **filter** hides an item through the stored `isFilteredOut` column, which is what makes
    ///   the sidebar counts a `fetchCount` instead of a scan. A pulled rule updates the rule and
    ///   nothing else, so the filter appeared in the other device's list and hid nothing.
    /// - An **account** switched off elsewhere arrives with no toggle to run, so its items keep
    ///   their `isAccountEnabled` flag and stay in the timeline.
    private func applyPulledSideEffects(_ outcome: SyncOutcome) async throws {
        if outcome.changedCollections.contains(.filter) {
            let reevaluator = FilterReevaluator(modelContainer: container)
            _ = try? await reevaluator.reapplyAll()
        }

        if outcome.changedCollections.contains(.account) {
            let context = ModelContext(container)
            _ = try? ThresholdService.reconcileAccountVisibility(in: context)
        }
    }

    /// Ingests every account of one kind, then syncs, then considers the badge.
    private func runIngest(_ kind: RefreshKind, trigger: RefreshTrigger) async throws {
        let sink = SwiftDataIngestSink(modelContainer: container)
        let context = ModelContext(container)

        var accounts: [AccountRecord] = []
        for account in try context.fetch(FetchDescriptor<AccountRecord>()) {
            guard account.isEnabled, account.kind.refreshKind == kind else { continue }
            accounts.append(account)
        }
        guard !accounts.isEmpty else { return }

        // Seeding a position writes a row dated now, and reduction takes the most recent row — so
        // a device that ingested before its first pull would seed itself to the top and outrank
        // the position it was about to receive. Held off until this device has pulled at least once.
        let maySeed = try Self.hasCompletedFirstPull(endpoint: endpoint, in: context)

        // Compiled once per run and handed to the sink, so ingest applies the user's rules as items
        // land rather than leaving them visible until the next re-evaluation pass.
        let engine = FilterEngine(try context.fetch(FetchDescriptor<FilterRule>()))
        var evaluator: SwiftDataIngestSink.FilterEvaluator?
        if !engine.isEmpty {
            evaluator = { subject in engine.hides(subject) }
        }

        await sink.configure(
            deviceID: DeviceIdentity.current.id,
            maySeedMarkers: maySeed,
            shouldHide: evaluator
        )

        let (built, connectionFailures) = connections.connect(accounts)
        var report = RefreshReport(kind: kind, failures: connectionFailures.map(Self.describe))
        // A connection failure is always a configuration problem — no credential, or an address
        // that will not parse — so none of them belongs in the retryable set.
        report.retryableFailures = []
        report.isComplete = connectionFailures.isEmpty

        let budget: IngestBudget = trigger == .backgroundTask ? .background() : .foreground

        if kind.ingestsItems {
            ingestsInFlight += 1
        }
        defer {
            if kind.ingestsItems {
                ingestsInFlight -= 1
            }
        }

        // Accounts that finished their whole walk. Retention is scoped to these rather than run
        // globally: an interrupted walk has not yet re-fetched what it was going to, so pruning on
        // the back of one evicts exactly the items the next run intended to restore.
        var completedAccountIDs: [UUID] = []

        for connection in built {
            do {
                let outcome = try await ingest(
                    connection,
                    sink: sink,
                    budget: budget,
                    historyWindowDays: historyWindowDays
                )
                report.itemsWritten += outcome.itemsWritten
                report.lateArrivals += outcome.lateArrivals
                if outcome.isComplete {
                    completedAccountIDs.append(connection.accountID)
                } else {
                    report.isComplete = false
                }
            } catch {
                // One unreachable server must not abandon the others: a phone on a train can reach
                // Mastodon while the FreshRSS box at home is behind a dead link, and the timeline
                // should still gain what it can.
                report.isComplete = false
                let described = Self.describe(error, for: connection, in: context)
                report.failures.append(described)
                // Reached the server and it went wrong — a timeout, a 5xx, a dropped connection.
                // That is exactly what backoff is for.
                report.retryableFailures.append(described)
            }
        }

        // A refresh that succeeded and still has no feeds to show is the most confusing state the
        // app can be in — everything reports fine and the sidebar is empty. Say so where the user
        // is already looking for account problems.
        for accountID in completedAccountIDs where Self.hasNoSubscribedSources(accountID, in: context) {
            report.failures.append(Self.describeEmptySubscriptionList(accountID, in: context))
        }

        onReport?(report)

        // Sync after ingest, so a position written during the walk goes out with it, and so the
        // badge below is computed from items and a position that are both current.
        var syncSucceeded = false
        do {
            try await runSync()
            syncSucceeded = true
        } catch {
            syncSucceeded = false
        }

        await publishBadge(report: report, syncSucceeded: syncSucceeded)

        // After the badge, so a fault in pruning cannot change the number that was just published.
        // The keep rules make the count invariant anyway, which is the point — but "anyway" is not
        // an ordering guarantee.
        await pruneCache(accountIDs: completedAccountIDs)

        // Reported after the badge so the caller's own retry policy still sees the failure, while
        // everything that could be done has been.
        //
        // Only a *retryable* failure may be thrown, because throwing is what earns the coordinator's
        // exponential backoff, and backing off is only ever the right answer to something that
        // might work later. An account with no stored credential will never work later — it needs
        // the user to sign in — and treating it as a transient fault was actively destructive: one
        // such account dragged the whole refresh into backoff, doubling to the thirty-minute cap,
        // and every *working* account stopped refreshing with it. Found on a real install where a
        // second, credential-less copy of each account had arrived by sync; the visible symptom
        // was simply that the app made no network requests for minutes at a time.
        //
        // The `itemsWritten == 0` term is what made it inevitable rather than occasional: a
        // refresh that legitimately finds nothing new is the normal case, so the broken account
        // was enough to fail every cycle forever.
        if report.itemsWritten == 0, let first = report.retryableFailures.first {
            throw RefreshEngineError.accountsFailed(first)
        }
    }

    private static func hasNoSubscribedSources(_ accountID: UUID, in context: ModelContext) -> Bool {
        let count = try? context.fetchCount(FetchDescriptor<CachedSource>(
            predicate: #Predicate { $0.accountID == accountID && $0.isSubscribed }
        ))
        return (count ?? 1) == 0
    }

    private static func describeEmptySubscriptionList(_ accountID: UUID, in context: ModelContext) -> String {
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountID })
        descriptor.fetchLimit = 1
        let name = (try? context.fetch(descriptor).first)?.displayName ?? "That account"
        return "\(name) answered, but listed no feeds. Check that the API password is right and that the account has subscriptions."
    }

    /// Prunes the cache for accounts that completed, and never lets a failure here fail a refresh.
    ///
    /// Retention is housekeeping: it can be skipped for a cycle with no consequence beyond disk,
    /// whereas turning it into a thrown error would drive the coordinator's backoff and report a
    /// successful refresh as broken.
    private func pruneCache(accountIDs: [UUID]) async {
        guard !accountIDs.isEmpty else { return }
        let service = RetentionService(modelContainer: container)
        // The fetch window is a setting, so it reaches retention from here rather than from the
        // injected policy — which a test still owns, to prune against numbers it can reason about.
        var policy = retention
        policy.historyWindowDays = historyWindowDays
        _ = try? await service.prune(accountIDs: accountIDs, policy: policy)
    }

    private func ingest(
        _ connection: AccountConnection,
        sink: SwiftDataIngestSink,
        budget: IngestBudget,
        historyWindowDays: Int
    ) async throws -> IngestOutcome {
        switch connection {
        case .freshRSS(let accountID, let client):
            let planner = FreshRSSIngestPlanner(client: client, sink: sink, accountID: accountID)
            // Subscriptions first, so a feed added on the server since the last run already has its
            // folder when its items land — otherwise they appear unfiled until the run after.
            let folders = try await planner.refreshSubscriptions()
            return try await planner.ingest(
                budget: budget,
                folders: folders,
                historyWindowDays: historyWindowDays
            )

        case .mastodon(let accountID, let client):
            let planner = MastodonIngestPlanner(client: client, sink: sink, accountID: accountID)
            try await planner.refreshSource()
            return try await planner.ingest(budget: budget, historyWindowDays: historyWindowDays)
        }
    }

    /// Re-publishes the badge after the reader's position settled.
    ///
    /// Called from the debounced fold commit, so it runs at most once per settled scroll rather
    /// than per scroll event. See ``BadgePublisher/publishPositionChange(count:)``.
    public func publishBadgeForPositionChange() async {
        guard ingestsInFlight == 0 else { return }

        let context = ModelContext(container)
        guard let count = try? ThresholdService.newerCount(for: badgeScope, in: context) else { return }
        _ = await badge.publishPositionChange(count: count)
    }

    private func publishBadge(report: RefreshReport, syncSucceeded: Bool) async {
        let context = ModelContext(container)
        guard let count = try? ThresholdService.newerCount(for: badgeScope, in: context) else { return }

        _ = await badge.publish(count: count, report: RefreshRunReport(
            ingestComplete: report.isComplete,
            syncSucceeded: syncSucceeded,
            didIngestItems: report.kind.ingestsItems
        ))
    }

    // MARK: - Helpers

    /// Whether this device has ever pulled from the sync endpoint.
    ///
    /// `true` when no endpoint is configured at all: there is then nothing to wait for, and a
    /// single-device install that never seeded a marker would show its entire backlog as newer.
    private static func hasCompletedFirstPull(
        endpoint: SyncEndpoint,
        in context: ModelContext
    ) throws -> Bool {
        guard endpoint.configuration() != nil else { return true }

        var descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.id == "default" })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.lastPulledAt != nil
    }

    private static func describe(_ error: AccountConnectionError) -> String {
        switch error {
        case .missingCredential(_, let name):
            // Names the button that fixes it. "Sign in again in Settings" sent people to the Add
            // Account menu, which is where it used to have to be done and does not sound like the
            // answer to being signed out. It also said "password" for a Mastodon account, whose
            // credential is an OAuth token.
            "\(name): not signed in on this device. Use the Sign In button on its row."
        case .invalidServerURL(_, let name):
            "\(name): the server address is not usable."
        }
    }

    /// Names the account an error came from, and says what actually went wrong.
    ///
    /// Matched case by case rather than by interpolating the error. `localizedDescription` on a
    /// `URLError` carries the failing URL, and a Google Reader URL is requested with the auth
    /// token in a header that some descriptions include — so the error is never printed, only
    /// read. What each case is *allowed* to contribute is decided here, one case at a time.
    ///
    /// The bare type name this used to print ("could not be refreshed (GReaderError)") satisfied
    /// that rule and was useless: it could not distinguish a wrong password from a reverse proxy
    /// serving an error page, which are the two things a user with an empty sidebar needs to tell
    /// apart. Withholding the reason does not protect anything — the failure is the user's own
    /// server talking to them about their own account.
    private static func describe(
        _ error: any Error,
        for connection: AccountConnection,
        in context: ModelContext
    ) -> String {
        let id = connection.accountID
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let name = (try? context.fetch(descriptor).first?.displayName) ?? nil

        return "\(name ?? "Account"): \(reason(for: error))"
    }

    /// A safe, specific sentence for one failure.
    private static func reason(for error: any Error) -> String {
        switch error {
        case let error as GReaderError:
            switch error {
            case .invalidCredentials:
                // Named precisely, because the API password is a *separate* password that
                // FreshRSS requires to be set before the API answers at all, and "wrong password"
                // sends people to re-check the one they log into the website with.
                return "the server rejected the credentials. Check the API password in your FreshRSS profile — it is separate from your login password."
            case .malformedLoginResponse:
                // The body is deliberately not quoted: a successful ClientLogin body contains the
                // auth token, and this case fires on bodies that were nearly one.
                return "signing in returned something that was not a FreshRSS login response. Check that the server address points at FreshRSS itself and not at a login page or proxy."
            case .invalidServerURL:
                return "the server address could not be turned into an API URL."
            case .unexpectedResponse(let detail):
                // A `DecodingError` description is a coding path and a debug message — no URL and
                // no headers — so it can be shown, and it is the only thing that identifies which
                // field of which response the server disagrees with us about.
                return "the server answered with JSON the app could not read. \(detail)"
            }

        case let error as HTTPError:
            switch error {
            case .status(let code, let body):
                // The body of a *failed* response carries the server's own explanation and cannot
                // contain a token we sent, so a short prefix of it is worth far more than the code
                // alone — a FreshRSS 401 and an nginx 401 read completely differently.
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                return detail.isEmpty
                    ? "the server answered HTTP \(code)."
                    : "the server answered HTTP \(code): \(detail)"
            case .notHTTP:
                return "the server answered with something that was not HTTP."
            case .rateLimited(let retryAfter):
                return "the server asked us to wait \(retryAfter.components.seconds)s before trying again."
            case .retriesExhausted:
                return "the server could not be reached."
            }

        case let error as URLError:
            // The code, not the description: `localizedDescription` embeds the failing URL.
            return "the server could not be reached (URLError \(error.errorCode))."

        default:
            return "it could not be refreshed (\(type(of: error)))."
        }
    }
}

public enum RefreshEngineError: Error, Sendable {
    case accountsFailed(String)
}

extension AccountKind {
    /// Which cadence an account's feeds refresh on.
    ///
    /// Lives here rather than on `RefreshKind` because the mapping is a property of the account
    /// type: a Mastodon timeline moves far faster than an RSS river, which is the whole reason the
    /// two have separate intervals.
    var refreshKind: RefreshKind {
        switch self {
        case .freshRSS: .freshRSSFeeds
        case .mastodon: .mastodonFeeds
        }
    }
}
