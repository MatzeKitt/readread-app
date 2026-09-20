import Foundation
import MastodonAPI
import Observation
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
#endif

/// Owns the long-lived machinery and connects it to the app's lifecycle.
///
/// Everything below this — the clients, the planners, the coordinators — was built and tested
/// without an app around it. This is the single place that starts it, hands it the settings, and
/// stops it, so there is one answer to "what is running and why" rather than lifecycle scattered
/// through views.
///
/// `@Observable` only for what the UI needs to show: whether a refresh is in flight, what the last
/// one did, and what failed. The work itself happens on actors.
@MainActor
@Observable
public final class AppServices {

    /// Whether a refresh of each kind is running, so the toolbar can show progress.
    public private(set) var refreshingKinds: Set<RefreshKind> = []

    /// What the last completed refresh did.
    public private(set) var lastReport: RefreshReport?

    /// Human-readable failures from the last refresh. Never carries a credential.
    public private(set) var failures: [String] = []

    /// Why the last Like or Boost did not happen, for the window to put in front of the reader.
    ///
    /// Published from here rather than held by the menu that started the action, because a context
    /// menu is gone by the time the request comes back — an alert attached to a menu item has no
    /// place in the view hierarchy left to present from. `RootView` owns the alert; this is what
    /// raises it. Set back to nil when the reader dismisses it.
    ///
    /// Kept separate from ``failures``, which is refresh reporting shown quietly on the accounts
    /// screen. This one is the direct answer to something the reader just asked for, so it
    /// interrupts.
    public var lastActionFailure: String?

    public var isRefreshing: Bool { !refreshingKinds.isEmpty }

    @ObservationIgnored public let container: ModelContainer
    @ObservationIgnored public let endpoint: SyncEndpoint

    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let engine: RefreshEngine

    /// The debounced local-change push. See ``syncSoon()``.
    @ObservationIgnored private var pendingPush: Task<Void, Never>?
    @ObservationIgnored private let coordinator: RefreshCoordinator
    @ObservationIgnored private let reachability = NetworkReachability()

    /// Writes settled reading positions on a context of its own. See ``PositionWriter``.
    @ObservationIgnored private let positions: PositionWriter

    /// Started once. Guarded because `.task` on a view can run again after a scene change, and
    /// starting the coordinator twice would double every timer.
    @ObservationIgnored private var hasStarted = false

    /// Whether the engine has been told what to do. Tracked separately from `hasStarted` because a
    /// background launch configures the engine without starting any timers. See
    /// ``performBackgroundRefresh()``.
    @ObservationIgnored private var hasConfiguredEngine = false

    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []

    /// The tail of the lifecycle chain, which is what keeps pause and resume in order.
    ///
    /// Every lifecycle notification used to spawn its own `Task`, and independent tasks have no
    /// ordering between them: the pause queued as the app was backgrounded could run *after* the
    /// resume queued when it came back, leaving a foreground app with no timers. Notifications
    /// themselves arrive in order on the main thread, so chaining each transition onto the previous
    /// one is enough to make the coordinator see them in the order they happened.
    @ObservationIgnored private var lifecycleTail: Task<Void, Never>?

    public init(container: ModelContainer, settings: SettingsModel) {
        self.container = container
        self.settings = settings
        endpoint = SyncEndpoint()

        let badge = BadgePublisher { count in
            await BadgeSetter.set(count)
        }
        let engine = RefreshEngine(container: container, badge: badge)
        self.engine = engine
        positions = PositionWriter(modelContainer: container)

        coordinator = RefreshCoordinator(
            settings: settings.refresh,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            operation: engine.operation()
        )
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        await configureEngine()

        // Settings are edited on the main actor and consumed by an actor, so the bridge is a
        // closure rather than the coordinator observing anything.
        settings.onRefreshSettingsChanged = { [coordinator, engine] updated in
            // `@MainActor` on the task, not merely `Task {}`. The closure is `@Sendable`, so a
            // bare task runs on the global executor — and `BackgroundRefresh.schedule` holds the
            // scheduled macOS activity in a `nonisolated(unsafe)` static that every other caller
            // touches from the main actor. Re-scheduling from a settings write is the one call
            // that would have arrived from somewhere else.
            Task { @MainActor in
                await coordinator.update(settings: updated)
                await engine.setBadgeScope(updated.badgeScope)
                await engine.setHistoryWindowDays(updated.historyWindowDays)
                // The cadence the background request was queued against has just changed, so the
                // queued request is measuring the old one.
                BackgroundRefresh.schedule(after: updated.backgroundRefreshSeconds)
            }
        }

        await reachability.start { [coordinator] in
            // A refresh that failed while offline is worth retrying the moment the network is back,
            // rather than waiting out a backoff that was measuring a problem which has gone away.
            await coordinator.refreshAll(trigger: .networkRestored)
        }

        observeLifecycle()

        // Queued at launch as well as on the way out, so a first-ever launch that is never
        // backgrounded cleanly still has a request pending.
        BackgroundRefresh.schedule(after: settings.refresh.backgroundRefreshSeconds)

        await coordinator.start()
    }

    /// Tells the engine what to refresh and where to report it.
    ///
    /// Separate from ``start()`` so a background launch can use it. When the system wakes the app
    /// for a `BGAppRefreshTask` there may be no window and no view tree at all, so the `.task` that
    /// calls `start()` never runs — and an engine that has not read its sync configuration cannot
    /// reach the endpoint, which would have made background refresh fail every single time in
    /// exactly the case it exists for.
    private func configureEngine() async {
        guard !hasConfiguredEngine else { return }
        hasConfiguredEngine = true

        await engine.setBadgeScope(settings.refresh.badgeScope)
        await engine.setHistoryWindowDays(settings.refresh.historyWindowDays)
        await engine.setActivityHandler { [weak self] kind, isRunning in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isRunning {
                    refreshingKinds.insert(kind)
                } else {
                    refreshingKinds.remove(kind)
                }
            }
        }
        await engine.setReportHandler { [weak self] report in
            Task { @MainActor [weak self] in
                self?.record(report)
            }
        }
        await engine.reloadSyncConfiguration()
    }

    /// Runs one refresh on behalf of a `BGAppRefreshTask`, and queues the next one.
    ///
    /// Re-queueing at the end is not housekeeping, it is the whole mechanism: a background task
    /// that does not submit its successor runs exactly once and then never again, which is
    /// indistinguishable from background refresh not working.
    ///
    /// The trigger matters too — `RefreshEngine` gives a `.backgroundTask` run the short ingest
    /// budget, so a large backlog stops cleanly at a section boundary and the next run resumes
    /// from the same cursor rather than the run being killed mid-page.
    public func performBackgroundRefresh() async {
        // Recorded and re-queued *before* the work, and that ordering is the fix rather than
        // tidiness.
        //
        // The system gives a `BGAppRefreshTask` a few tens of seconds and then expires it, which
        // cancels the task running this. Anything after the `await` below is then not reached — so
        // with the re-submit at the end, the first run that took too long was also the last one
        // that ever happened, and background refresh stopped for good with no way to tell from the
        // outside. Queued first, the successor survives the run being cut off, which is exactly
        // the case where continuing matters most: an interrupted ingest has a cursor waiting.
        //
        // The cost is that `earliestBeginDate` is measured from the start of the run rather than
        // its end — half a minute against a fifteen-minute cadence.
        BackgroundRefresh.recordRun()
        BackgroundRefresh.schedule(after: settings.refresh.backgroundRefreshSeconds)

        await configureEngine()
        await coordinator.refreshAll(trigger: .backgroundTask)
    }

    /// What background refresh has actually been doing, for the settings screen.
    public var backgroundRefreshDiagnostics: BackgroundRefresh.Diagnostics {
        BackgroundRefresh.diagnostics
    }

    /// What the automatic cadences have been doing, for the settings screen.
    ///
    /// The macOS half of the same question `backgroundRefreshDiagnostics` answers on iOS: there is
    /// no `BGTaskScheduler` on the Mac, so the timers in `RefreshCoordinator` are the whole
    /// mechanism and the coordinator is the only thing that knows their state.
    public func refreshDiagnostics() async -> RefreshCoordinator.Diagnostics {
        await coordinator.diagnostics()
    }

    public func stop() async {
        lifecycleTail?.cancel()
        lifecycleTail = nil
        await coordinator.stop()
        await reachability.stop()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
        hasStarted = false
    }

    /// Refreshes everything now, for ⌘R and pull-to-refresh.
    public func refreshNow() async {
        await coordinator.refreshAll(trigger: .manual)
    }

    /// Pushes and pulls sync state now, without touching the feeds.
    ///
    /// Used after a local edit: a position or a saved item should reach the other devices in
    /// seconds, and re-walking the feeds to achieve that would be absurd.
    /// Brings the app icon badge in line with a reading position that has just settled.
    ///
    /// Fire-and-forget from the caller's point of view: the timeline commits its fold on a
    /// debounce and must not wait on an actor hop to finish drawing.
    public func positionSettled() {
        Task { [engine] in await engine.publishBadgeForPositionChange() }
        syncSoon()
    }

    /// Writes a settled reading position, off the main actor.
    ///
    /// Here rather than in the timeline because the writer needs the container, and because what
    /// follows a successful write — the badge, the debounced push — is this type's business
    /// anyway. See ``PositionWriter`` for why it cannot simply be wrapped in a `Task` at the call
    /// site: a `ModelContext` is not `Sendable`, and the main one belongs to the main actor.
    ///
    /// - Returns: Whether anything was written. `false` means the item had left the store, and the
    ///   caller should not record the position as reported.
    @discardableResult
    public func commitPosition(scope: ScopeID, itemID: String) async -> Bool {
        let deviceID = DeviceIdentity.current.id
        guard await positions.write(scope: scope, itemID: itemID, deviceID: deviceID) else {
            return false
        }
        positionSettled()
        return true
    }

    /// Pushes local changes after a short delay, collapsing a burst into one request.
    ///
    /// The plan called for this and nothing was ever wired to it: `syncNow()` existed with no
    /// callers, so every local change — a position, a saved item, a filter — waited for the next
    /// thirty-second tick, and a change made just after a tick took the better part of a minute to
    /// reach the other device *plus* however long until that device polled. Two devices could sit
    /// a minute apart and look as though nothing was syncing at all.
    ///
    /// Two seconds, and debounced, because the callers are things a reader does repeatedly:
    /// scrolling settles a fold every second and a half, and pushing on each one would turn
    /// reading into a request per second.
    public func syncSoon() {
        pendingPush?.cancel()
        pendingPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await coordinator.refresh(.syncState, trigger: .localChange)
        }
    }

    public func syncNow() async {
        await coordinator.refresh(.syncState, trigger: .localChange)
    }

    /// Re-reads the endpoint after it has been edited, and syncs against it.
    public func syncEndpointChanged() async {
        await engine.reloadSyncConfiguration()
        await coordinator.refresh(.syncState, trigger: .manual)
    }

    /// Refreshes after an account is added or removed.
    public func accountsChanged() async {
        await coordinator.refreshAll(trigger: .manual)
    }

    // MARK: - Writing to Mastodon

    /// Favourites or boosts a post, as one of the reader's accounts.
    ///
    /// The only path in the app that writes to somebody else's server, and it is reached only from
    /// a menu the reader opened on a post they were looking at. It is not on a timer, it is not
    /// part of a refresh, and nothing calls it speculatively.
    ///
    /// - Parameter account: The account to act as. Usually the one the post arrived in; the menu
    ///   offers the others when there are any, which is what the resolve step in
    ///   `StatusInteractions` exists for.
    /// - Returns: A sentence to show when it failed, or nil on success. A `Failure` never reaches
    ///   the UI as itself — see ``describe(_:)``.
    @discardableResult
    public func favouriteOrBoost(
        _ action: StatusInteractions.Action,
        on item: CachedItem,
        as account: StatusInteractions.Actor
    ) async -> String? {
        // The *displayed* status's id, which is what the server has to be given: a boost's own id
        // names the act of boosting. Decoded here rather than kept as a column because this runs
        // once per deliberate click, not once per row — which is the line the denormalised columns
        // on `CachedItem` are drawn along.
        guard
            item.kind == .status,
            let payload = item.mastodonPayload,
            let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
        else {
            return Self.describe(StatusInteractions.Failure.notAStatus)
        }

        let statusID = status.displayStatus.id.rawValue
        let statusURL = item.url
        let isOwningAccount = item.accountID == account.id

        do {
            let outcome = try await StatusInteractions().perform(
                action,
                statusID: statusID,
                statusURL: statusURL,
                as: account,
                isOwningAccount: isOwningAccount
            )
            StatusInteractions.apply(outcome, to: item)
            lastActionFailure = nil
            // Saved here rather than left to the next refresh: the row has just been redrawn from
            // these values, and losing them to a crash would leave a post the reader watched turn
            // into a Like showing Like again.
            try? modelContext.save()
            return nil
        } catch let failure as StatusInteractions.Failure {
            return report(failure)
        } catch {
            return report(.failed)
        }
    }

    /// Posts a reply to a Mastodon post, as one of the reader's accounts.
    ///
    /// Takes the parent's *displayed* id and URL from the row for the same reason
    /// ``favouriteOrBoost(_:on:as:)`` does: a boost's own id names the act of boosting, and the
    /// URL is the only name for a post that two instances agree on.
    ///
    /// On success the parent's reply count goes up by one locally. Not a guess — the instance has
    /// just accepted the reply, so one more reply is exactly what is true — and the alternative is a
    /// row that says "3 replies" directly after the reader wrote the fourth.
    ///
    /// - Returns: A sentence to show when it failed, or nil on success.
    @discardableResult
    public func reply(
        _ reply: StatusInteractions.Reply,
        to item: CachedItem,
        as account: StatusInteractions.Actor
    ) async -> String? {
        guard
            item.kind == .status,
            let payload = item.mastodonPayload,
            let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
        else {
            return Self.describe(StatusInteractions.Failure.notAStatus)
        }

        do {
            try await StatusInteractions().reply(
                reply,
                toStatusID: status.displayStatus.id.rawValue,
                statusURL: item.url,
                as: account,
                isOwningAccount: item.accountID == account.id
            )
            item.replyCount += 1
            lastActionFailure = nil
            try? modelContext.save()
            return nil
        } catch let failure as StatusInteractions.Failure {
            return report(failure)
        } catch {
            return report(.failed)
        }
    }

    /// Mutes a post's author, and clears what they have already put in the timeline.
    ///
    /// Two halves that have to be read together. The instance stops delivering their posts, which
    /// only affects what arrives *next*; and the rows already fetched are deleted, which is what
    /// makes the action mean what the menu item says. See ``AuthorMute``.
    ///
    /// Always as the account the post arrived in — see ``StatusInteractions/mute(authorAccountID:as:)``
    /// for why muting is not an action other accounts can take on your behalf. The caller does not
    /// get to choose, which is why there is no `as:` here.
    ///
    /// The server half goes first. A local sweep that ran before it would leave the reader looking
    /// at an empty space while the instance carried on sending, and a failed mute would have taken
    /// their posts away without silencing anyone.
    ///
    /// - Returns: A sentence to show when it failed, or nil on success.
    @discardableResult
    public func muteAuthor(of item: CachedItem) async -> String? {
        guard
            item.kind == .status,
            let payload = item.mastodonPayload,
            let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
        else {
            return Self.describe(StatusInteractions.Failure.notAStatus)
        }

        // The *displayed* status's author: the person whose words these are. On a boost that is the
        // original poster rather than whoever boosted it in, which matches the name the row shows.
        let author = status.displayStatus.account
        let owningAccountID = item.accountID

        guard let record = account(withID: owningAccountID) else {
            return report(.noAuthorToMute)
        }
        let actor = StatusInteractions.Actor(
            id: record.id,
            displayName: record.displayName,
            serverURLString: record.serverURLString
        )

        do {
            try await StatusInteractions().mute(authorAccountID: author.id, as: actor)
        } catch let failure as StatusInteractions.Failure {
            return report(failure)
        } catch {
            return report(.failed)
        }

        // Only after the instance agreed. The handle comes from the payload that was just decoded,
        // which is the same `acct` the rows were written from — see `AuthorMute.normalised(_:)` for
        // why an exact match is what is wanted here.
        _ = try? AuthorMute.removeItems(
            byAuthorHandle: author.acct,
            accountID: owningAccountID,
            in: modelContext
        )
        lastActionFailure = nil
        try? modelContext.save()
        return nil
    }

    /// Says that a row cannot be acted on, in the same words every other such failure uses.
    ///
    /// For the two actions that open something before they do anything — the reply composer and the
    /// mute confirmation. Both need the row's stored payload to decode, and when it does not there
    /// is nothing to open; without this the menu item would simply do nothing at all, which is
    /// indistinguishable from the app being broken.
    public func reportUnusableStatus() {
        report(.notAStatus)
    }

    /// One of the reader's accounts, by id.
    private func account(withID id: UUID) -> AccountRecord? {
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Publishes a failure and hands the same sentence back to the caller.
    ///
    /// Both, deliberately: the property is what raises the alert, and the return value is what
    /// makes this testable without a window.
    @discardableResult
    private func report(_ failure: StatusInteractions.Failure) -> String {
        let message = Self.describe(failure)
        lastActionFailure = message
        return message
    }

    /// The main-actor context this class writes through.
    ///
    /// Its own, rather than a view's `@Environment(\.modelContext)`: this is called from a menu
    /// action, and the row being mutated belongs to whichever context fetched it. `mainContext` is
    /// the one every view's environment context *is* on this platform, so a save here is the same
    /// save a view would have made.
    private var modelContext: ModelContext { container.mainContext }

    /// Turns a failure into a sentence, case by case.
    ///
    /// Never interpolates the error. A `MastodonError` or an `HTTPError` can carry the request that
    /// produced it, and that request's `Authorization` header is the account's access token — so
    /// printing one would put a credential on screen. Each case decides what it may contribute,
    /// and the account's display name is the most any of them says.
    private static func describe(_ failure: StatusInteractions.Failure) -> String {
        switch failure {
        case .notAStatus:
            String(localized: "That only works on Mastodon posts.")
        case .missingCredential(let account):
            String(localized: "\(account) is signed out. Sign in again to act as it.")
        case .invalidServerURL(let account):
            String(localized: "\(account) has no usable server address.")
        case .writeNotAuthorized(let account):
            // The case a reader hits first after each of these features ships, so it says what to
            // do rather than what went wrong: the token was granted before the app asked for the
            // scope the action needs, and only signing in again can widen it. It names the button
            // in so many words — there is a Reauthorise on the account's row in Settings, and a
            // message that only says "sign in again" sends people to Add Account instead.
            String(localized: "\(account) has not allowed this yet. Use Reauthorise on its row in Settings to grant it.")
        case .tokenRevoked(let account):
            String(localized: "\(account) is no longer authorised. Sign in to it again.")
        case .notFoundOnInstance(let account):
            String(localized: "\(account)'s server cannot find this post.")
        case .rejected(let account):
            // The instance said what was wrong with it, in the response body, and that body is
            // deliberately not repeated here — see `StatusInteractions.Failure`. Length is what it
            // is nearly always, so length is what this names.
            String(localized: "\(account)'s server would not accept that. It may be too long.")
        case .noAuthorToMute:
            String(localized: "This post does not say enough about its author to mute them.")
        case .failed:
            String(localized: "That did not work. The server may be unreachable.")
        }
    }

    // MARK: - Reporting

    private func record(_ report: RefreshReport) {
        lastReport = report
        failures = report.failures

        // The background-refresh diary is written where a *scheduled* wake happens — the
        // `.backgroundTask` handler on iOS, the activity block on macOS — and not from here. This
        // used to record any feed cadence that ran while the Mac was not frontmost, which counted
        // something real but not the same something the iOS figure counts. See
        // ``BackgroundRefresh/recordRun(at:)``.
    }

    // MARK: - Platform lifecycle

    private func observeLifecycle() {
        #if os(macOS)
        // The Mac keeps this app open for days, so the two things that matter are: stop polling
        // when the window is not visible, and catch up immediately after the machine wakes.
        add(NSApplication.didChangeOcclusionStateNotification) { [weak self] in
            guard let self else { return }
            let isVisible = NSApp.occlusionState.contains(.visible)
            let pauseWhenHidden = settings.refresh.pauseWhenHidden
            enqueueLifecycle { [coordinator] in
                if isVisible {
                    await coordinator.resume(trigger: .activated)
                } else if pauseWhenHidden {
                    await coordinator.pause()
                }
            }
        }

        // The Mac's own background refresh, and the answer to it not working at all.
        //
        // The occlusion pause above is right — polling behind a hidden window is battery spent on
        // nobody — but on its own it meant a Mac with the window covered refreshed *nothing* until
        // somebody brought it back to the front. The system's own scheduler covers that window,
        // which is the same division of labour iOS has: the app's timers while it is on screen,
        // the OS while it is not. See ``BackgroundRefresh``.
        //
        // `refreshDue` rather than `resume`, deliberately: resuming would restart the timers and
        // clear the pause, so the first background wake would undo the very pause it exists to
        // work around.
        //
        // Registered here rather than scheduled here: ``start()`` submits the request a few lines
        // after calling this, and both platforms go through that one call site.
        BackgroundRefresh.setOperation { [coordinator] in
            await coordinator.refreshDue(trigger: .backgroundTask)
        }

        add(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            guard let self else { return }
            // Not chained: this is a whole feed walk, not a state transition, and putting it in
            // the lifecycle chain would make the next pause wait minutes for it.
            Task { [coordinator] in
                await coordinator.refreshAll(trigger: .systemWake)
            }
        }
        #endif

        #if os(iOS)
        // The iOS half of the same job, and it was simply missing — there was a `#if os(macOS)`
        // block and nothing else, so on a phone the timers started once at launch and were never
        // touched again.
        //
        // That is not a small omission on iOS, because the system *suspends* the process. A
        // sleeping timer task does not fire while suspended and does not fire on resume either: it
        // resumes its `Task.sleep` against a clock that has since moved on, so a phone that has
        // been in a pocket for an hour comes back and waits out the remainder of a thirty-second
        // sleep before it thinks to check anything. The visible symptom is a device that syncs
        // once when you launch it and then appears never to poll again — which is exactly what a
        // server log showed: one request from the phone against dozens from the Mac.
        add(UIApplication.didBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            enqueueLifecycle { [coordinator] in
                // `resume` rather than `refreshAll`: it restarts the timers *and* runs whatever was
                // missed, so the phone catches up on the way in rather than on the next tick.
                await coordinator.resume(trigger: .activated)
            }
        }

        add(UIApplication.didEnterBackgroundNotification) { [weak self] in
            guard let self else { return }
            // Asked for here because this is the moment the answer is known: the app is leaving,
            // so whatever the timers would have done next has to be done by the system instead.
            BackgroundRefresh.schedule(after: settings.refresh.backgroundRefreshSeconds)
            enqueueLifecycle { [coordinator] in
                // Paused rather than left running: the work would not complete anyway once the
                // process is suspended, and a half-finished ingest is the thing the two-cursor
                // scheme exists to make survivable rather than something to invite.
                //
                // `honouringPreference: false`, because "pause when hidden" is a macOS choice
                // about polling behind a hidden window. Here the process is about to be suspended
                // either way, and skipping the pause only means `resume` declines to catch up —
                // which is precisely how a phone ended up refreshing once per launch and never
                // again.
                await coordinator.pause(honouringPreference: false)
            }
        }
        #endif

        add(processInfoPowerStateNotification) { [weak self] in
            guard let self else { return }
            let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { [coordinator] in
                await coordinator.setLowPowerMode(isLowPower)
            }
        }
    }

    private var processInfoPowerStateNotification: Notification.Name {
        NSNotification.Name.NSProcessInfoPowerStateDidChange
    }

    /// Runs one lifecycle transition after the previous one has finished.
    ///
    /// Ordering only, not exclusion: the coordinator is an actor and already serialises its own
    /// state. What this adds is that pause-then-resume reaches it in that order — see
    /// ``lifecycleTail``.
    private func enqueueLifecycle(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycleTail
        lifecycleTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func add(
        _ name: Notification.Name,
        center: NotificationCenter = .default,
        handler: @escaping @MainActor () -> Void
    ) {
        lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
            // Hopped onto the main actor rather than asserted into it.
            //
            // `addObserver(forName:object:queue:using:)` with `queue: .main` does *not* guarantee
            // the block runs on the main thread's dispatch queue — `OperationQueue.main` can run
            // it synchronously on whichever thread posted the notification. `MainActor
            // .assumeIsolated` then trips a libdispatch queue assertion and kills the process:
            //
            //     BUG IN CLIENT OF LIBDISPATCH: Assertion failed:
            //     Block was not expected to execute on queue [com.apple.main-thread]
            //
            // Which is what happened on macOS the moment a Mastodon sign-in came back from the
            // browser — the auth sheet closing posts an occlusion change from a background thread.
            // The hop costs a turn of the run loop and cannot be wrong.
            Task { @MainActor in handler() }
        })
    }
}

/// Writes the app icon badge.
///
/// Wrapped so `BadgePublisher` — which is where the *policy* about when a badge may be written
/// lives — has no platform code in it, and so the app can be built for a target that has no badge
/// without that policy needing a conditional.
enum BadgeSetter {

    static func set(_ count: Int) async {
        #if os(macOS)
        await MainActor.run {
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        #else
        // Asked for the first time there is actually a number to show.
        //
        // `setBadgeCount` is silently ignored on iOS without authorisation, and nothing had ever
        // requested it — so the badge could not appear on a phone however well refreshing worked,
        // which is most of what "nothing happens unless I open the app" looks like from the home
        // screen. The plan called for this at first run; on reflection this is the better moment,
        // because a prompt that arrives with a count behind it can be answered on the merits,
        // where one on a first launch with no accounts yet is a prompt about nothing. A denial is
        // effectively permanent — only Settings can undo it — so when it is asked matters.
        if count > 0 {
            await requestBadgeAuthorizationIfNeeded()
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    #if !os(macOS)
    /// Requests badge authorisation, once, and only while it has never been answered.
    ///
    /// `.badge` alone: this app sends no notifications and plays no sounds, and asking for
    /// permissions it will never use is how an app gets refused the one it needs.
    private static func requestBadgeAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.badge])
    }
    #endif
}
