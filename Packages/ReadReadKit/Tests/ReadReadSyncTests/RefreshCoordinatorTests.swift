import Foundation
import ReadReadModel
import ReadReadTestSupport
import Testing

@testable import ReadReadSync

/// Scheduling-policy tests, driven by a stub operation and a clock that does not sleep.
///
/// Every case here is behaviour that would otherwise only be observable by leaving the app running
/// for an hour and watching what it does to the battery.
@Suite("RefreshCoordinator")
struct RefreshCoordinatorTests {

    /// Records what the coordinator asked to run, and can be made to fail or block on demand.
    private actor Recorder {

        private(set) var calls: [(kind: RefreshKind, trigger: RefreshTrigger)] = []
        private var failingKinds: Set<RefreshKind> = []
        /// A *list* of continuations, not one. Two kinds can be blocked at the same time — that is
        /// exactly what `differentKindsRunConcurrently` asserts — and a single slot would silently
        /// overwrite the first, leaking a task that never resumes.
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var shouldBlock = false

        /// `nonisolated` so the coordinator can be constructed synchronously; the returned
        /// closure hops onto the actor itself.
        nonisolated func operation() -> RefreshCoordinator.Operation {
            { [weak self] kind, trigger in
                guard let self else { return }
                try await run(kind: kind, trigger: trigger)
            }
        }

        private func run(kind: RefreshKind, trigger: RefreshTrigger) async throws {
            calls.append((kind, trigger))
            if shouldBlock {
                await withCheckedContinuation { continuation in
                    gates.append(continuation)
                }
            }
            if failingKinds.contains(kind) {
                throw StubError.failed
            }
        }

        func setFailing(_ kinds: Set<RefreshKind>) { failingKinds = kinds }
        func setBlocking(_ blocking: Bool) { shouldBlock = blocking }

        /// Releases one blocked call.
        func release() {
            guard !gates.isEmpty else { return }
            gates.removeFirst().resume()
        }

        /// Releases every blocked call, so a test cannot leave one parked forever.
        func releaseAll() {
            let pending = gates
            gates.removeAll()
            for continuation in pending { continuation.resume() }
        }

        var blockedCount: Int { gates.count }

        var callCount: Int { calls.count }
        func count(of kind: RefreshKind) -> Int { calls.filter { $0.kind == kind }.count }
        var triggers: [RefreshTrigger] { calls.map(\.trigger) }

        enum StubError: Error { case failed }
    }

    /// A wall clock the test moves by hand.
    ///
    /// Separate from `TestClock`, which controls *waiting*. Resuming asks how much time has passed
    /// since a kind last ran — the question a suspended app comes back to — and that is a reading
    /// off a calendar, not a sleep that can be advanced.
    private final class Wall: @unchecked Sendable {

        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_700_000_000)

        var now: Date {
            lock.withLock { date }
        }

        func advance(by seconds: TimeInterval) {
            lock.withLock { date += seconds }
        }

        func reader() -> @Sendable () -> Date {
            { [self] in now }
        }
    }

    private func makeCoordinator(
        settings: RefreshSettings = .default,
        isLowPower: Bool = false,
        wall: Wall = Wall()
    ) -> (RefreshCoordinator, Recorder, TestClock) {
        let recorder = Recorder()
        let clock = TestClock()
        let coordinator = RefreshCoordinator(
            settings: settings,
            isLowPowerMode: isLowPower,
            clock: clock,
            now: wall.reader(),
            operation: recorder.operation()
        )
        return (coordinator, recorder, clock)
    }

    // MARK: - Cadences

    /// The three kinds are separately configurable because their natural rates differ by an order
    /// of magnitude. Forcing one number on all three gives either a stale timeline or needless
    /// load on the FreshRSS host.
    @Test("Each kind has its own interval")
    func kindsHaveSeparateIntervals() async {
        let settings = RefreshSettings(syncStateSeconds: 30, mastodonSeconds: 300, freshRSSSeconds: 900)
        let (coordinator, _, _) = makeCoordinator(settings: settings)

        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(30))
        #expect(await coordinator.nextDelay(for: .mastodonFeeds) == .seconds(300))
        #expect(await coordinator.nextDelay(for: .freshRSSFeeds) == .seconds(900))
    }

    @Test("A kind set to off is never scheduled")
    func disabledKindIsNotScheduled() async {
        let settings = RefreshSettings(syncStateSeconds: nil, mastodonSeconds: 300, freshRSSSeconds: nil)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)

        await coordinator.refreshAll(trigger: .manual)

        #expect(await recorder.count(of: .syncState) == 0)
        #expect(await recorder.count(of: .mastodonFeeds) == 1)
        #expect(await recorder.count(of: .freshRSSFeeds) == 0)
        #expect(await coordinator.nextDelay(for: .syncState) == nil)
    }

    @Test("Low Power Mode stretches every interval")
    func lowPowerStretchesIntervals() async {
        let settings = RefreshSettings(syncStateSeconds: 30, lowPowerMultiplier: 4)
        let (coordinator, _, _) = makeCoordinator(settings: settings, isLowPower: true)

        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(120))
    }

    @Test("Low Power Mode can be ignored")
    func lowPowerCanBeIgnored() async {
        let settings = RefreshSettings(syncStateSeconds: 30, respectLowPowerMode: false)
        let (coordinator, _, _) = makeCoordinator(settings: settings, isLowPower: true)

        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(30))
    }

    // MARK: - Background wakes

    /// The macOS background activity's entry point, and the reason it is not `resume`.
    ///
    /// A Mac hides its window and the coordinator suspends its timers; the system then wakes the
    /// app periodically to do the refreshing that the timers are not doing. Resuming there would
    /// clear the pause and restart the timers, so the *first* background wake would undo the pause
    /// it exists to work around — and from then on the app would poll behind a hidden window, which
    /// is the thing `pauseWhenHidden` was switched on to prevent.
    @Test("A background wake runs due work without lifting the pause")
    func backgroundWakeKeepsThePause() async {
        let wall = Wall()
        let (coordinator, recorder, _) = makeCoordinator(
            settings: RefreshSettings(syncStateSeconds: 30, mastodonSeconds: 300, freshRSSSeconds: 900),
            wall: wall
        )

        await coordinator.refreshAll(trigger: .manual)
        let afterFirst = await recorder.callCount
        await coordinator.pause()
        #expect(await coordinator.isCurrentlyPaused)

        wall.advance(by: 1_000)
        await coordinator.refreshDue(trigger: .backgroundTask)

        #expect(await recorder.callCount == afterFirst + 3)
        #expect(await coordinator.isCurrentlyPaused)
        #expect(await recorder.triggers.suffix(3).allSatisfy { $0 == .backgroundTask })
    }

    /// Due-ness rather than everything, because on a Mac a background wake lands constantly while
    /// the timers are perfectly healthy — the app is behind another window but its own window is
    /// still visible. Refreshing everything there would re-walk feeds a timer walked seconds ago.
    @Test("A background wake refreshes only what has fallen due")
    func backgroundWakeSkipsWhatIsNotDue() async {
        let wall = Wall()
        let (coordinator, recorder, _) = makeCoordinator(
            settings: RefreshSettings(syncStateSeconds: 30, mastodonSeconds: 300, freshRSSSeconds: 900),
            wall: wall
        )

        await coordinator.refreshAll(trigger: .manual)
        let afterFirst = await recorder.callCount

        // Past the sync poll's interval and nothing else's.
        wall.advance(by: 60)
        await coordinator.refreshDue(trigger: .backgroundTask)

        #expect(await recorder.callCount == afterFirst + 1)
        #expect(await recorder.count(of: .syncState) == 2)
        #expect(await recorder.count(of: .mastodonFeeds) == 1)
        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
    }

    // MARK: - Single-flight

    /// A timer tick landing during a manual refresh must join the run in progress. Without this
    /// the same pages are fetched twice, and with the ingest walk that also means two runs
    /// competing over the same cursor.
    @Test("Overlapping refreshes of one kind collapse into a single run")
    func overlappingRefreshesCollapse() async {
        let (coordinator, recorder, _) = makeCoordinator()
        await recorder.setBlocking(true)

        // Start one run and let it reach the gate.
        let first = Task { await coordinator.refresh(.freshRSSFeeds, trigger: .manual) }
        while await recorder.callCount == 0 { await Task.yield() }

        // Five more triggers arrive while it is still in flight.
        let others = (0..<5).map { _ in
            Task { await coordinator.refresh(.freshRSSFeeds, trigger: .timer) }
        }
        for _ in 0..<50 { await Task.yield() }

        #expect(await recorder.callCount == 1)

        await recorder.setBlocking(false)
        await recorder.releaseAll()
        await first.value
        for task in others { await task.value }

        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
    }

    /// Single-flight is per kind, not global: a slow feed ingest must not hold up the cheap
    /// position sync, which is the whole reason they have separate cadences.
    @Test("Different kinds run concurrently")
    func differentKindsRunConcurrently() async {
        let (coordinator, recorder, _) = makeCoordinator()
        await recorder.setBlocking(true)

        let feeds = Task { await coordinator.refresh(.freshRSSFeeds, trigger: .timer) }
        while await recorder.callCount < 1 { await Task.yield() }
        let sync = Task { await coordinator.refresh(.syncState, trigger: .timer) }
        while await recorder.callCount < 2 { await Task.yield() }

        // Both entered the operation, so neither blocked the other.
        #expect(await recorder.callCount == 2)

        await recorder.setBlocking(false)
        await recorder.releaseAll()
        await feeds.value
        await sync.value
    }

    // MARK: - Backoff

    /// A server that is down must not be retried at the base interval forever.
    @Test("Consecutive failures back off exponentially")
    func failuresBackOffExponentially() async {
        let settings = RefreshSettings(syncStateSeconds: 60)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)
        await recorder.setFailing([.syncState])

        var delays: [Duration?] = [await coordinator.nextDelay(for: .syncState)]
        for _ in 0..<4 {
            await coordinator.refresh(.syncState, trigger: .timer)
            delays.append(await coordinator.nextDelay(for: .syncState))
        }

        #expect(delays == [
            .seconds(60),    // healthy
            .seconds(120),   // 1 failure
            .seconds(240),   // 2
            .seconds(480),   // 3
            .seconds(960),   // 4
        ])
        #expect(await coordinator.failureCount(for: .syncState) == 4)
    }

    @Test("Backoff is capped")
    func backoffIsCapped() async {
        let settings = RefreshSettings(syncStateSeconds: 60)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)
        await recorder.setFailing([.syncState])

        for _ in 0..<20 {
            await coordinator.refresh(.syncState, trigger: .timer)
        }

        #expect(await coordinator.nextDelay(for: .syncState) == RefreshCoordinator.maxBackoff)
    }

    @Test("A success resets the backoff")
    func successResetsBackoff() async {
        let settings = RefreshSettings(syncStateSeconds: 60)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)

        await recorder.setFailing([.syncState])
        await coordinator.refresh(.syncState, trigger: .timer)
        await coordinator.refresh(.syncState, trigger: .timer)
        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(240))

        await recorder.setFailing([])
        await coordinator.refresh(.syncState, trigger: .timer)

        #expect(await coordinator.failureCount(for: .syncState) == 0)
        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(60))
    }

    /// One kind failing must not slow the others down; they talk to different servers.
    @Test("Backoff is tracked per kind")
    func backoffIsPerKind() async {
        let settings = RefreshSettings(syncStateSeconds: 60, mastodonSeconds: 60)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)
        await recorder.setFailing([.syncState])

        await coordinator.refresh(.syncState, trigger: .timer)
        await coordinator.refresh(.mastodonFeeds, trigger: .timer)

        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(120))
        #expect(await coordinator.nextDelay(for: .mastodonFeeds) == .seconds(60))
    }

    /// Cancellation is not a server failure and must not earn a backoff penalty — otherwise
    /// backgrounding the app a few times would leave it barely refreshing.
    @Test("A cancelled run is not counted as a failure")
    func cancellationIsNotAFailure() async {
        let (coordinator, recorder, _) = makeCoordinator()
        await recorder.setBlocking(true)

        let task = Task { await coordinator.refresh(.freshRSSFeeds, trigger: .timer) }
        while await recorder.callCount == 0 { await Task.yield() }
        await coordinator.stop()
        await recorder.setBlocking(false)
        await recorder.releaseAll()
        await task.value

        #expect(await coordinator.failureCount(for: .freshRSSFeeds) == 0)
    }

    // MARK: - Pausing

    @Test("A paused coordinator does no timed work")
    func pausedCoordinatorDoesNothing() async {
        let (coordinator, recorder, _) = makeCoordinator()

        await coordinator.pause()
        await coordinator.refresh(.freshRSSFeeds, trigger: .timer)

        #expect(await recorder.callCount == 0)
        #expect(await coordinator.isCurrentlyPaused)
    }

    /// Forgetting what fell due while paused would leave the timeline stale until the next tick,
    /// which for feeds could be an hour after the window is shown again.
    @Test("Work missed while paused is run on resume")
    func missedWorkRunsOnResume() async {
        let (coordinator, recorder, clock) = makeCoordinator()
        // Hold time completely still: this test is about the pause bookkeeping, and timer ticks
        // firing underneath it would make the counts meaningless.
        clock.sleepLimit = 0

        await coordinator.pause()
        await coordinator.refresh(.freshRSSFeeds, trigger: .timer)
        await coordinator.refresh(.syncState, trigger: .timer)
        #expect(await recorder.callCount == 0)

        await coordinator.resume()

        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
        #expect(await recorder.count(of: .syncState) == 1)
        #expect(await coordinator.isCurrentlyPaused == false)
    }

    @Test("Resume runs each missed kind once, however many ticks were skipped")
    func resumeCoalescesMissedTicks() async {
        let (coordinator, recorder, clock) = makeCoordinator()
        clock.sleepLimit = 0

        await coordinator.pause()
        for _ in 0..<10 {
            await coordinator.refresh(.freshRSSFeeds, trigger: .timer)
        }
        await coordinator.resume()

        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
    }

    /// A manual refresh is the user asking now. Pausing is a battery optimisation and must never
    /// swallow an explicit request.
    @Test("A manual refresh works even while paused")
    func manualRefreshIgnoresPause() async {
        let (coordinator, recorder, _) = makeCoordinator()

        await coordinator.pause()
        await coordinator.refresh(.freshRSSFeeds, trigger: .manual)

        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
    }

    @Test("Pausing is skipped when the setting is off")
    func pauseCanBeDisabled() async {
        let settings = RefreshSettings(pauseWhenHidden: false)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings)

        await coordinator.pause()
        await coordinator.refresh(.freshRSSFeeds, trigger: .timer)

        #expect(await coordinator.isCurrentlyPaused == false)
        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
    }

    /// The bug this covers made iOS look as though auto-refresh did not exist.
    ///
    /// A suspended process fires no timer ticks, so the old "run what was missed" bookkeeping came
    /// back empty however long the phone had been away, and the app restarted its timers and then
    /// waited out a full interval before touching the feeds. A reader saw new items only after
    /// opening the app and pulling down.
    @Test("Resuming after a long absence refreshes what has gone stale")
    func resumeCatchesUpOnElapsedTime() async {
        let wall = Wall()
        let (coordinator, recorder, clock) = makeCoordinator(wall: wall)
        clock.sleepLimit = 0

        // A launch, which runs everything and records when.
        await coordinator.start()
        let afterLaunch = await recorder.callCount
        #expect(afterLaunch == RefreshKind.allCases.count)

        await coordinator.pause(honouringPreference: false)
        // An hour in a pocket. No tick fires, because the process is not running.
        wall.advance(by: 3_600)
        await coordinator.resume()

        // Everything is stale by now, so everything runs again.
        #expect(await recorder.callCount == afterLaunch * 2)
        #expect(await recorder.triggers.contains(.activated))
    }

    /// The other half of the same rule. Flicking through the app switcher must not re-walk the
    /// feeds each time, which is precisely what "refresh everything on activation" would do.
    @Test("Resuming after a moment refreshes only what is due")
    func resumeSkipsWhatIsStillFresh() async {
        let wall = Wall()
        let (coordinator, recorder, clock) = makeCoordinator(wall: wall)
        clock.sleepLimit = 0

        await coordinator.start()
        let afterLaunch = await recorder.callCount

        await coordinator.pause(honouringPreference: false)
        // Long enough for the thirty-second sync cadence, nowhere near the five- and
        // fifteen-minute feed ones.
        wall.advance(by: 45)
        await coordinator.resume()

        #expect(await recorder.count(of: .syncState) == 2)
        #expect(await recorder.count(of: .mastodonFeeds) == 1)
        #expect(await recorder.count(of: .freshRSSFeeds) == 1)
        #expect(await recorder.callCount == afterLaunch + 1)
    }

    /// Backoff is measured in the same currency as the cadence, so a server that is down must not
    /// be probed again every time the reader opens the app — which on a phone is constantly.
    @Test("A backing-off kind is not due again until its backoff has elapsed")
    func resumeRespectsBackoff() async {
        let wall = Wall()
        let settings = RefreshSettings(
            syncStateSeconds: nil,
            mastodonSeconds: nil,
            freshRSSSeconds: 60
        )
        let (coordinator, recorder, clock) = makeCoordinator(settings: settings, wall: wall)
        clock.sleepLimit = 0
        await recorder.setFailing([.freshRSSFeeds])

        // Two failures, so the next attempt is owed four times the interval.
        await coordinator.refresh(.freshRSSFeeds, trigger: .manual)
        await coordinator.refresh(.freshRSSFeeds, trigger: .manual)
        #expect(await coordinator.failureCount(for: .freshRSSFeeds) == 2)

        await coordinator.pause(honouringPreference: false)
        wall.advance(by: 90)
        await coordinator.resume()
        #expect(await recorder.count(of: .freshRSSFeeds) == 2)

        await coordinator.pause(honouringPreference: false)
        wall.advance(by: 300)
        await coordinator.resume()
        #expect(await recorder.count(of: .freshRSSFeeds) == 3)
    }

    /// On iOS the preference is not the question: the system suspends the process either way, and
    /// declining to pause only means declining to catch up afterwards.
    @Test("iOS pauses even with the pause preference switched off")
    func pauseCanIgnoreThePreference() async {
        let settings = RefreshSettings(pauseWhenHidden: false)
        let (coordinator, _, _) = makeCoordinator(settings: settings)

        await coordinator.pause(honouringPreference: false)

        #expect(await coordinator.isCurrentlyPaused)
    }

    @Test("A kind that is switched off is never due")
    func disabledKindIsNotDue() async {
        let settings = RefreshSettings(syncStateSeconds: nil)
        let (coordinator, recorder, clock) = makeCoordinator(settings: settings)
        clock.sleepLimit = 0

        await coordinator.pause()
        await coordinator.resume()

        #expect(await recorder.count(of: .syncState) == 0)
    }

    @Test("Resuming with nothing due does nothing")
    func resumeWithNothingDueIsNoOp() async {
        let wall = Wall()
        let (coordinator, recorder, clock) = makeCoordinator(wall: wall)
        clock.sleepLimit = 0

        // A launch stamps every kind as having just run.
        await coordinator.start()
        let afterLaunch = await recorder.callCount

        // No time passes, so nothing has gone stale.
        await coordinator.resume()

        #expect(await recorder.callCount == afterLaunch)
    }

    /// The bug that left iOS refreshing nothing at all, and it was not the timers.
    ///
    /// Pausing and resuming each reached the coordinator as their own task, and two tasks have no
    /// ordering: the pause queued on the way out could run *after* the resume queued on the way
    /// back in. `resume` opened with `guard isPaused else { return }`, so it found the flag still
    /// clear, returned without catching up, and the pause it had overtaken then cancelled every
    /// timer — leaving a foreground app with no timers and no pending catch-up. Due-ness is a
    /// question about elapsed time, and the answer cannot depend on which task won a race.
    @Test("A resume that arrives before its pause still catches up")
    func resumeCatchesUpWithoutHavingPaused() async {
        let wall = Wall()
        let (coordinator, recorder, clock) = makeCoordinator(wall: wall)
        clock.sleepLimit = 0

        await coordinator.start()
        let afterLaunch = await recorder.callCount

        // The pause never ran: the process was suspended before its task got a turn.
        wall.advance(by: 3_600)
        await coordinator.resume()

        #expect(await coordinator.isCurrentlyPaused == false)
        #expect(await recorder.callCount == afterLaunch * 2)
    }

    /// The tail of the same problem. A pause landing after the resume must not leave the app
    /// running with no timers, and the only thing that can rescue it is the next resume being
    /// willing to act on elapsed time rather than on the flag.
    @Test("A pause landing after a resume is recovered by the next one")
    func latePauseIsRecoveredOnNextResume() async {
        let wall = Wall()
        let (coordinator, recorder, clock) = makeCoordinator(wall: wall)
        clock.sleepLimit = 0

        await coordinator.start()
        let afterLaunch = await recorder.callCount

        // The inverted order: resume first, pause second.
        await coordinator.resume()
        await coordinator.pause(honouringPreference: false)
        #expect(await coordinator.isCurrentlyPaused)

        wall.advance(by: 3_600)
        await coordinator.resume()

        #expect(await coordinator.isCurrentlyPaused == false)
        #expect(await recorder.callCount == afterLaunch * 2)
    }

    // MARK: - Triggers

    @Test("The trigger is passed through to the operation")
    func triggerIsPassedThrough() async {
        let (coordinator, recorder, _) = makeCoordinator()

        await coordinator.refresh(.syncState, trigger: .networkRestored)
        await coordinator.refresh(.syncState, trigger: .systemWake)

        #expect(await recorder.triggers == [.networkRestored, .systemWake])
    }

    @Test("refreshAll covers every enabled kind")
    func refreshAllCoversEnabledKinds() async {
        let (coordinator, recorder, _) = makeCoordinator()

        await coordinator.refreshAll(trigger: .launch)

        #expect(await recorder.callCount == RefreshKind.allCases.count)
    }

    @Test("A manual refresh reports whether it succeeded")
    func manualRefreshReportsResult() async {
        let (coordinator, recorder, _) = makeCoordinator()

        #expect(await coordinator.refreshReportingResult(.syncState) == true)

        await recorder.setFailing([.syncState])
        #expect(await coordinator.refreshReportingResult(.syncState) == false)
    }

    // MARK: - Timers

    @Test("Starting runs everything immediately and then schedules")
    func startRunsImmediately() async {
        let (coordinator, recorder, clock) = makeCoordinator()
        clock.sleepLimit = 0

        await coordinator.start()
        #expect(await recorder.callCount == RefreshKind.allCases.count)

        await coordinator.stop()
    }

    @Test("The timer loop sleeps for the configured interval")
    func timerSleepsForInterval() async throws {
        let settings = RefreshSettings(syncStateSeconds: 30, mastodonSeconds: nil, freshRSSSeconds: nil)
        let (coordinator, recorder, clock) = makeCoordinator(settings: settings)
        // Allow exactly one tick, then hold time still.
        clock.sleepLimit = 1

        await coordinator.start()
        // Let the loop reach its first sleep.
        for _ in 0..<200 where clock.sleepCount == 0 { await Task.yield() }

        #expect(clock.sleeps.first == .seconds(30))
        // The immediate run at start, plus whatever ticks the fake clock let through.
        #expect(await recorder.count(of: .syncState) >= 1)

        await coordinator.stop()
    }

    @Test("Stopping cancels the timers")
    func stopCancelsTimers() async {
        let (coordinator, _, clock) = makeCoordinator()
        clock.sleepLimit = 0

        await coordinator.start()
        await coordinator.stop()

        #expect(await coordinator.isRunning(.syncState) == false)
    }

    /// Restarting resets every timer's phase, so doing it on an unchanged settings write would
    /// keep pushing the next run further into the future — a refresh that never quite happens.
    @Test("Writing unchanged settings does not restart the timers")
    func unchangedSettingsDoNotRestart() async {
        let settings = RefreshSettings(syncStateSeconds: 30)
        let (coordinator, _, clock) = makeCoordinator(settings: settings)
        clock.sleepLimit = RefreshKind.allCases.count

        await coordinator.start()
        // Waited for the count to go *quiet*, not for it to reach a particular number.
        //
        // Both earlier attempts at this guessed at the number and both were wrong: each timer
        // sleeps once, does its work, then sleeps again — and that second sleep parks against
        // `sleepLimit` while still counting. So the settled total is two per kind, not one, and any
        // fixed target samples partway up the ramp and fails a test about restarts with no restart
        // involved. Waiting for stability needs no arithmetic about the loop's shape at all.
        await settle(clock)
        let sleepsBefore = clock.sleepCount

        await coordinator.update(settings: settings)
        await settle(clock)

        #expect(clock.sleepCount == sleepsBefore)

        await coordinator.stop()
    }

    /// Yields until the clock's sleep count stops moving.
    ///
    /// A number of consecutive unchanged reads rather than a fixed number of yields: what matters
    /// is that every timer has reached its parking sleep, and how many yields that takes depends on
    /// scheduling rather than on anything the test controls.
    private func settle(_ clock: TestClock, quietYields: Int = 40, limit: Int = 2_000) async {
        var last = -1
        var quiet = 0
        for _ in 0..<limit {
            let count = clock.sleepCount
            quiet = (count == last) ? quiet + 1 : 0
            last = count
            if quiet >= quietYields { return }
            await Task.yield()
        }
    }

    // MARK: - Diagnostics

    /// The Mac has no `BGTaskScheduler` to ask whether unattended refreshing is happening, so this
    /// snapshot is the only answer available — which makes it worth asserting that it says what it
    /// appears to say.
    @Test("A cadence reports when it ran and when it is next due")
    func diagnosticsReportSchedule() async {
        let wall = Wall()
        let settings = RefreshSettings(syncStateSeconds: 30, mastodonSeconds: 300, freshRSSSeconds: 900)
        let (coordinator, _, _) = makeCoordinator(settings: settings, wall: wall)

        await coordinator.refresh(.syncState, trigger: .manual)
        let ran = wall.now
        wall.advance(by: 10)

        let diagnostics = await coordinator.diagnostics()
        let sync = diagnostics.cadences.first { $0.kind == .syncState }

        #expect(sync?.lastRunAt == ran)
        #expect(sync?.nextDueAt == ran.addingTimeInterval(30))
        #expect(sync?.failureCount == 0)
        #expect(diagnostics.isPaused == false)
    }

    /// "Never" and "off" are different answers, and conflating them would have the screen report a
    /// switched-off cadence as one that has stopped working.
    @Test("A cadence that has never run is due now; one that is off is due never")
    func diagnosticsSeparateNeverFromOff() async {
        let wall = Wall()
        let settings = RefreshSettings(syncStateSeconds: 30, mastodonSeconds: nil, freshRSSSeconds: nil)
        let (coordinator, _, _) = makeCoordinator(settings: settings, wall: wall)

        let diagnostics = await coordinator.diagnostics()

        let sync = diagnostics.cadences.first { $0.kind == .syncState }
        #expect(sync?.lastRunAt == nil)
        #expect(sync?.nextDueAt == wall.now)

        let mastodon = diagnostics.cadences.first { $0.kind == .mastodonFeeds }
        #expect(mastodon?.lastRunAt == nil)
        #expect(mastodon?.nextDueAt == nil)
    }

    /// The point of showing this at all: a long silence has two innocent explanations and one that
    /// needs acting on, and a backoff is the one that needs acting on. So the next-due time has to
    /// be the *backed-off* one rather than the nominal interval.
    @Test("A failing cadence reports its backoff, not its interval")
    func diagnosticsReportBackoff() async {
        let wall = Wall()
        let settings = RefreshSettings(syncStateSeconds: 30, mastodonSeconds: nil, freshRSSSeconds: nil)
        let (coordinator, recorder, _) = makeCoordinator(settings: settings, wall: wall)
        await recorder.setFailing([.syncState])

        await coordinator.refresh(.syncState, trigger: .manual)
        await coordinator.refresh(.syncState, trigger: .manual)
        let ran = wall.now

        let sync = await coordinator.diagnostics().cadences.first { $0.kind == .syncState }

        #expect(sync?.failureCount == 2)
        // Two failures, so four times the interval.
        #expect(sync?.nextDueAt == ran.addingTimeInterval(120))
    }

    @Test("Pausing is reported")
    func diagnosticsReportPause() async {
        let (coordinator, _, _) = makeCoordinator()

        await coordinator.pause()

        #expect(await coordinator.diagnostics().isPaused)
    }

    /// Every kind, every time, in declaration order — the screen draws a row per cadence and a
    /// missing one would read as a cadence that does not exist.
    @Test("Every cadence is reported, in order")
    func diagnosticsCoverEveryKind() async {
        let (coordinator, _, _) = makeCoordinator()

        #expect(await coordinator.diagnostics().cadences.map(\.kind) == RefreshKind.allCases)
    }
}
