import Foundation
import ReadReadModel

/// Why a refresh ran. Recorded so the UI can distinguish a user-initiated refresh from a timer.
public enum RefreshTrigger: String, Sendable {
    case launch
    case timer
    case activated
    case networkRestored
    case systemWake
    case manual
    case localChange
    case backgroundTask
}

/// Drives the automatic refresh cadences.
///
/// ## What this type is actually for
///
/// The hard parts of auto-refresh are not the timers, they are the four things around them, and
/// each is a real bug if left out:
///
/// - **Single-flight per kind.** A timer tick landing during a manual refresh must join the run in
///   progress, not start a second one that fetches the same pages again.
/// - **Backoff on failure.** A server that is down must not be retried every 30 seconds forever.
/// - **Pausing when nobody is watching.** On macOS the app is left open for days; polling behind a
///   hidden window is pure battery cost.
/// - **Catching up on resume.** A paused coordinator that simply forgets its due work would leave
///   the timeline stale until the next tick, which for feeds could be an hour.
///
/// The work itself is injected, so all of that is testable against a stub operation and a fake
/// clock without touching the network.
public actor RefreshCoordinator {

    /// Performs one refresh of a kind. Injected so the scheduling policy can be tested in
    /// isolation from what it schedules.
    public typealias Operation = @Sendable (RefreshKind, RefreshTrigger) async throws -> Void

    /// Longest a backoff will ever delay a retry.
    static let maxBackoff: Duration = .seconds(30 * 60)

    private let operation: Operation
    private let clock: any Clock<Duration>

    /// Wall-clock reading, injected so ``isDue(_:)`` is testable.
    ///
    /// Separate from `clock`, which measures *waiting*. Due-ness is a question about how much time
    /// has passed while this process was not running, and an `any Clock<Duration>` cannot answer
    /// it: with only `Duration` as its primary associated type, its `Instant` is not a type this
    /// code can name, let alone subtract.
    private let now: @Sendable () -> Date

    private var settings: RefreshSettings

    /// Set from the environment; `false` when running headless in tests.
    private var isLowPowerMode: Bool

    /// True while no window is visible, or the app is backgrounded.
    private var isPaused = false

    /// One in-flight task per kind. The value is what makes overlapping triggers collapse.
    private var running: [RefreshKind: Task<Void, any Error>] = [:]

    /// Consecutive failures per kind, driving the backoff curve.
    private var failures: [RefreshKind: Int] = [:]

    /// The timer loop for each enabled kind.
    private var timers: [RefreshKind: Task<Void, Never>] = [:]

    /// When each kind last finished a run, successfully or not.
    ///
    /// This is what ``resume(trigger:)`` measures against, and the reason there is no longer a set
    /// of "kinds whose tick was missed while paused". That set could only ever be filled by a
    /// timer *firing* while paused, which on iOS never happens: the process is suspended, so its
    /// sleeping timer tasks fire nothing at all. See ``resume(trigger:)``.
    private var lastRunAt: [RefreshKind: Date] = [:]

    public init(
        settings: RefreshSettings = .default,
        isLowPowerMode: Bool = false,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now },
        operation: @escaping Operation
    ) {
        self.settings = settings
        self.isLowPowerMode = isLowPowerMode
        self.clock = clock
        self.now = now
        self.operation = operation
    }

    // MARK: - Lifecycle

    /// Starts the timers and performs an immediate first refresh of everything enabled.
    public func start(trigger: RefreshTrigger = .launch) async {
        restartTimers()
        await refreshAll(trigger: trigger)
    }

    /// Cancels every timer and in-flight run.
    public func stop() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    public func update(settings: RefreshSettings) {
        let changed = settings != self.settings
        self.settings = settings
        // Only restart when something actually changed: restarting resets every timer's phase, so
        // doing it on every settings read would keep pushing the next run further away.
        if changed { restartTimers() }
    }

    public func setLowPowerMode(_ isLowPower: Bool) {
        guard isLowPower != isLowPowerMode else { return }
        isLowPowerMode = isLowPower
        restartTimers()
    }

    /// Suspends timers. Runs already in flight are left to finish.
    ///
    /// - Parameter honouringPreference: whether `pauseWhenHidden` may veto this. iOS passes
    ///   `false`, because there the pause is not an optimisation to opt out of: the system is
    ///   about to suspend the process whether or not the preference says so, and pausing is how
    ///   the coordinator records that a catch-up will be owed. Left honoured on macOS, where a
    ///   hidden window really is a choice about polling behind it.
    public func pause(honouringPreference: Bool = true) {
        if honouringPreference, !settings.pauseWhenHidden { return }
        guard !isPaused else { return }
        isPaused = true
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    /// Resumes timers and immediately runs whatever has fallen due.
    ///
    /// Due-ness is measured against when each kind **last ran**, not against which timers happened
    /// to tick while paused — and that distinction is the whole reason iOS looked as though it
    /// never refreshed on its own. A suspended process fires no ticks, so nothing was ever
    /// recorded as missed: a phone that had been in a pocket for an hour came back, restarted its
    /// timers, and then waited out a further fifteen minutes before so much as looking at the
    /// feeds. Elapsed time is the question that actually wants answering, and it answers the
    /// macOS case identically.
    /// ## Why this does not require having been paused
    ///
    /// It used to open with `guard isPaused else { return }`, and that single line cost iOS its
    /// automatic refreshing in a way that looked like the timers being broken.
    ///
    /// Pausing and resuming both arrive as notifications, and each hands its work to the actor as
    /// its own `Task`. Two independent tasks have no ordering, so the pause queued as the app was
    /// backgrounded could just as well run *after* the resume queued when it came back — and then
    /// the resume found `isPaused` still `false`, returned without catching up, and the pause it
    /// had overtaken went on to cancel every timer. The app was left in the foreground, unpaused
    /// by preference and with no timers at all, refreshing nothing until it was backgrounded and
    /// opened again. Which is exactly what "there is still no auto-update on iOS" looks like.
    /// The ordering is now imposed by the caller as well, but a resume that silently does nothing
    /// depending on task scheduling is not a thing to leave lying around.
    ///
    /// The other half of the same problem needs no ordering to bite: a process that is suspended
    /// before its pause runs keeps timers that are *asleep against a clock that has moved on*, so
    /// they fire late by however long the phone was in a pocket. Restarting them is the fix, and
    /// being overdue is the signal that it is needed.
    public func resume(trigger: RefreshTrigger = .activated) async {
        let due = RefreshKind.allCases.filter { isDue($0) }

        // Overdue work is proof the timers are either cancelled or stale, whichever way the flag
        // reads. Nothing overdue and not paused means the timers are healthy and mid-cycle, and
        // restarting them there would reset their phase — on macOS, where showing and hiding a
        // window posts this repeatedly, that alone could push the next run out indefinitely.
        if isPaused || !due.isEmpty {
            isPaused = false
            restartTimers()
        }

        // Sequential and in declaration order, so positions are pulled before the feeds are
        // walked. The badge is a function of both, and fresh items against a stale marker
        // over-count.
        for kind in due {
            await refresh(kind, trigger: trigger)
        }
    }

    /// Runs whatever has fallen due, leaving the pause exactly as it was.
    ///
    /// For a wake the *system* scheduled, which on macOS is the only thing that refreshes while
    /// the window is hidden — see ``BackgroundRefresh``. ``resume(trigger:)`` is the wrong call
    /// there twice over: it clears `isPaused` and restarts the timers, which is a decision for the
    /// window becoming visible again, not for an activity that is about to hand the CPU back and
    /// leave the app napping. Restarting them would also mean the pause never took effect at all
    /// after the first background wake.
    ///
    /// Due-ness rather than everything, so a wake that lands while the timers *are* running — the
    /// app in the background with a visible window, which happens constantly on a Mac — does not
    /// re-walk feeds a timer has just walked. `refresh(_:trigger:)` would join a run in flight
    /// anyway; this avoids starting one that has nothing to fetch.
    public func refreshDue(trigger: RefreshTrigger) async {
        // Sequential and in declaration order, so positions are pulled before the feeds are
        // walked: the badge is a function of both, and fresh items against a stale marker
        // over-count. Same reasoning as `resume(trigger:)`.
        for kind in RefreshKind.allCases where isDue(kind) {
            await refresh(kind, trigger: trigger)
        }
    }

    /// Whether `kind` has gone long enough without a run that another one is due.
    ///
    /// A kind that has never run counts as due, which is the state a relaunch leaves behind.
    func isDue(_ kind: RefreshKind) -> Bool {
        guard settings.isEnabled(kind) else { return false }
        guard let last = lastRunAt[kind] else { return true }
        // `nextDelay` rather than the plain interval, so a kind that is currently backing off is
        // not probed again on every trip through the app switcher — which would defeat the
        // backoff entirely on the platform where the app is foregrounded most often.
        guard let delay = nextDelay(for: kind) else { return false }
        return now().timeIntervalSince(last) >= delay.seconds
    }

    public var isCurrentlyPaused: Bool { isPaused }

    public func failureCount(for kind: RefreshKind) -> Int { failures[kind] ?? 0 }

    public func isRunning(_ kind: RefreshKind) -> Bool { running[kind] != nil }

    // MARK: - Running

    /// Refreshes every enabled kind, concurrently.
    public func refreshAll(trigger: RefreshTrigger) async {
        await withTaskGroup(of: Void.self) { group in
            for kind in RefreshKind.allCases where settings.isEnabled(kind) {
                group.addTask { [weak self] in
                    await self?.refresh(kind, trigger: trigger)
                }
            }
        }
    }

    /// Refreshes one kind, joining a run already in progress.
    ///
    /// Errors are swallowed here by design: this is called from timers and lifecycle events where
    /// there is no caller to hand a failure to. The failure is recorded as backoff instead, and
    /// surfaced through `SyncState.lastErrorDescription` for the settings screen.
    public func refresh(_ kind: RefreshKind, trigger: RefreshTrigger) async {
        // A tick that lands after the pause is dropped rather than remembered; `resume` works out
        // what is owed from `lastRunAt` instead.
        if isPaused, trigger == .timer { return }

        if let existing = running[kind] {
            // Join rather than start a second run of the same kind.
            _ = try? await existing.value
            return
        }

        let task = Task<Void, any Error> { [operation] in
            try await operation(kind, trigger)
        }
        running[kind] = task

        do {
            try await task.value
            failures[kind] = 0
            lastRunAt[kind] = now()
        } catch is CancellationError {
            // A cancelled run is not a failure and must not earn a backoff penalty.
        } catch {
            failures[kind, default: 0] += 1
            lastRunAt[kind] = now()
        }

        running[kind] = nil
    }

    /// Runs one kind and reports whether it succeeded. For a manual refresh, which has a caller.
    @discardableResult
    public func refreshReportingResult(_ kind: RefreshKind, trigger: RefreshTrigger = .manual) async -> Bool {
        let before = failures[kind] ?? 0
        await refresh(kind, trigger: trigger)
        return (failures[kind] ?? 0) <= before
    }

    // MARK: - Timers

    private func restartTimers() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        guard !isPaused else { return }

        for kind in RefreshKind.allCases where settings.isEnabled(kind) {
            timers[kind] = Task { [weak self] in
                await self?.runTimerLoop(for: kind)
            }
        }
    }

    private func runTimerLoop(for kind: RefreshKind) async {
        while !Task.isCancelled {
            guard let delay = nextDelay(for: kind) else { return }

            do {
                try await clock.sleep(for: delay)
            } catch {
                return // Cancelled.
            }
            guard !Task.isCancelled else { return }

            await refresh(kind, trigger: .timer)
        }
    }

    /// How long to wait before the next run of `kind`.
    ///
    /// The base interval while healthy; an exponentially growing delay after consecutive failures,
    /// capped, so a server that is down is probed occasionally rather than hammered.
    func nextDelay(for kind: RefreshKind) -> Duration? {
        guard let base = settings.interval(for: kind, isLowPower: isLowPowerMode) else { return nil }

        let failureCount = failures[kind] ?? 0
        guard failureCount > 0 else { return base }

        let exponent = min(failureCount, 16)
        let scaled = base.seconds * Double(1 << exponent)
        return .seconds(min(scaled, Self.maxBackoff.seconds))
    }
}

// MARK: - Diagnostics

public extension RefreshCoordinator {

    /// What the automatic cadences have actually been doing.
    ///
    /// Exists for the same reason ``BackgroundRefresh/Diagnostics`` does, one platform over.
    /// Unattended refreshing is unfalsifiable from the outside: a timeline that has not changed
    /// looks identical whether the timers are running and the feeds are quiet, whether they were
    /// paused behind a hidden window and nobody has resumed them, or whether every run has been
    /// failing into a backoff that is now half an hour long. Those have three different fixes, and
    /// no way to tell them apart by looking at the app.
    ///
    /// On iOS the analogous question is whether the system ran the task at all, which
    /// `BGTaskScheduler` alone can answer. On the Mac there is no scheduler to ask — the timers in
    /// this actor *are* the mechanism, so this is where the answer lives.
    struct Diagnostics: Sendable, Equatable {

        /// One cadence's state.
        public struct Cadence: Sendable, Equatable, Identifiable {

            public var kind: RefreshKind

            /// When it last finished, successfully or not. `nil` before its first run.
            public var lastRunAt: Date?

            /// When the next run falls due, or `nil` when this cadence is switched off.
            ///
            /// Computed from ``lastRunAt`` and the *current* delay, so a cadence that is backing
            /// off reports the backed-off time rather than its nominal interval — which is the
            /// number worth seeing, since it is the one that explains a long silence.
            public var nextDueAt: Date?

            /// Consecutive failures. Anything above zero means the delay above is a backoff.
            public var failureCount: Int

            public var isRunning: Bool

            public var id: RefreshKind { kind }

            public init(
                kind: RefreshKind,
                lastRunAt: Date? = nil,
                nextDueAt: Date? = nil,
                failureCount: Int = 0,
                isRunning: Bool = false
            ) {
                self.kind = kind
                self.lastRunAt = lastRunAt
                self.nextDueAt = nextDueAt
                self.failureCount = failureCount
                self.isRunning = isRunning
            }
        }

        /// Whether the timers are currently suspended — no visible window, or backgrounded.
        public var isPaused: Bool

        /// Every cadence, in declaration order.
        public var cadences: [Cadence]

        public init(isPaused: Bool = false, cadences: [Cadence] = []) {
            self.isPaused = isPaused
            self.cadences = cadences
        }
    }

    /// A snapshot of the cadences, for the settings screen.
    func diagnostics() -> Diagnostics {
        Diagnostics(
            isPaused: isCurrentlyPaused,
            cadences: RefreshKind.allCases.map { kind in
                Diagnostics.Cadence(
                    kind: kind,
                    lastRunAt: lastRunAt[kind],
                    nextDueAt: nextDue(for: kind),
                    failureCount: failureCount(for: kind),
                    isRunning: isRunning(kind)
                )
            }
        )
    }

    /// When `kind` next falls due, as a wall-clock date.
    ///
    /// A kind that has never run is due immediately rather than at an unknown time: that is the
    /// state a relaunch leaves behind, and it is what ``isDue(_:)`` already reports.
    private func nextDue(for kind: RefreshKind) -> Date? {
        guard let delay = nextDelay(for: kind) else { return nil }
        guard let last = lastRunAt[kind] else { return now() }
        return last.addingTimeInterval(delay.seconds)
    }
}
