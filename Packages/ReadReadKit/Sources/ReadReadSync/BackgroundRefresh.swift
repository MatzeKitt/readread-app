#if os(iOS)
import BackgroundTasks
#endif
import Foundation

/// The app's background refresh request, for when the app is not running at all.
///
/// The timers in ``RefreshCoordinator`` only run while the process does, and on iOS that is a
/// small fraction of the day: the system suspends the app moments after it leaves the screen and
/// then kills it whenever it needs the memory. Everything that made auto-refresh work on the Mac
/// therefore stopped at the app switcher, and the only thing that ever brought new items in was
/// opening the app and pulling down.
///
/// `BGAppRefreshTaskRequest` is the answer the system offers: a few tens of seconds, granted at a
/// time of its choosing, for exactly this. The identifier, the `fetch` background mode and the
/// `BGTaskSchedulerPermittedIdentifiers` entry were all already declared in `Info.plist` — nothing
/// ever registered a handler or submitted a request against them.
///
/// Deliberately thin. There is nothing here worth testing through a seam (`BGTaskScheduler` cannot
/// be driven from a unit test); the part that carries a decision is
/// ``RefreshSettings/backgroundRefreshSeconds``, which is tested on its own.
///
/// ## The Mac, which needs a different mechanism for the same job
///
/// `BGTaskScheduler` is declared unavailable on macOS and so is `BackgroundTask.appRefresh`, so
/// for a long time the Mac had no scheduling half at all — it relied entirely on
/// ``RefreshCoordinator``'s own timers. Which do not run when it matters: the coordinator
/// suspends them while no window is visible (`pauseWhenHidden`, on by default), and a Mac left
/// open all day spends most of it with the window behind something else. The reported symptom was
/// the honest one — background refresh on the Mac did not work at all.
///
/// `NSBackgroundActivityScheduler` is the mechanism that does exist there. It is the Cocoa face of
/// XPC activity: the system picks the moment, weighing energy, thermal state and CPU, and — the
/// part a `Task.sleep` cannot claim — it wraps the work in `beginActivity`, so App Nap does not
/// defer it while the app sits in the background with nothing on screen. Apple's guidance is to
/// use it for work on intervals "measured in 10s of minutes or more", which
/// ``RefreshSettings/backgroundRefreshSeconds`` already is: it carries a fifteen-minute floor.
///
/// What it cannot do is start an app that is not running. There is no macOS equivalent of iOS's
/// background launch — not a silent push, which reaches only a running app and would need APNs
/// this design deliberately does without; not an activity, which is scheduled by the process that
/// registered it. Waking a *quit* Mac app needs a `launchd` agent installed beside it, which is a
/// different piece of software. So this covers "running, nobody looking", which is where the Mac
/// actually spends its day.
public enum BackgroundRefresh {

    /// The registered task identifier.
    ///
    /// Derived from the bundle identifier rather than written out, because `Info.plist` derives its
    /// `BGTaskSchedulerPermittedIdentifiers` entry the same way — `$(PRODUCT_BUNDLE_IDENTIFIER)
    /// .refresh`. A literal here would be a second copy of the same string, free to drift, and the
    /// symptom of drift is an exception at launch rather than anything subtle.
    public static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.kittmedia.ReadRead"
        return "\(bundle).refresh"
    }

    /// Asks the system to run a background refresh no sooner than `seconds` from now.
    ///
    /// - Parameter seconds: from ``RefreshSettings/backgroundRefreshSeconds``. `nil` means every
    ///   cadence is switched off, which cancels any pending request rather than queueing one:
    ///   a reader who has turned refreshing off has turned it off everywhere.
    /// - Returns: Whether a request is now queued.
    @discardableResult
    public static func schedule(after seconds: Int?) -> Bool {
        #if os(macOS)
        guard let seconds, let operation else {
            cancelActivity()
            recordSchedule(accepted: false)
            return false
        }

        // Replaced rather than adjusted. The scheduler re-reads `interval` when its block calls
        // the completion handler, so changing it on a live object takes effect a whole interval
        // late — and this is called precisely *because* the interval changed.
        cancelActivity()

        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.interval = TimeInterval(seconds)
        // Above the default `.background`, which is scheduled at the system's leisure and can mean
        // hours. `.utility` still lets the system choose the moment — it just stops it treating a
        // feed reader's refresh as maintenance it can put off indefinitely.
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            // Recorded before the work, like the iOS path and for the same reason: a run the
            // system cuts short is still evidence that background refreshing happens, and that is
            // the case most worth telling apart from never running at all.
            recordRun()
            // The block is handed a completion handler and must call it, or the activity is never
            // rescheduled. Bridged through a task because the work is `async`; the handler is
            // documented `Sendable` and may be called from anywhere.
            Task {
                await operation()
                completion(.finished)
            }
        }
        activity = scheduler
        recordSchedule(accepted: true)
        return true
        #elseif os(iOS)
        guard let seconds else {
            cancel()
            recordSchedule(accepted: false)
            return false
        }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // The earliest the system *may* run it, not when it will. It routinely waits far longer,
        // which is why the app must never treat a background run as its only refresh.
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(seconds))

        do {
            try BGTaskScheduler.shared.submit(request)
            recordSchedule(accepted: true)
            return true
        } catch {
            // Refusals are ordinary and none of them are worth interrupting a reader for: the
            // simulator has no scheduler at all, and a device with Background App Refresh switched
            // off in Settings declines every request. The foreground cadences still work.
            //
            // Recorded rather than swallowed, though. A silently declined request and a request the
            // system simply has not chosen to run yet produce the identical symptom, and only one
            // of them has a fix the reader can apply.
            recordSchedule(accepted: false)
            return false
        }
        #else
        return false
        #endif
    }

    /// Drops any pending request.
    public static func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        #elseif os(macOS)
        cancelActivity()
        #endif
    }

    #if os(macOS)
    /// The activity currently registered, so a settings change replaces it rather than stacking
    /// another one behind it.
    ///
    /// `nonisolated(unsafe)` for the same reason as ``defaults``: it is touched from the main actor
    /// only — ``schedule(after:)`` and ``cancel()`` are both called from `AppServices` — and the
    /// alternative, an actor around one object, would make a scheduling call asynchronous for no
    /// benefit. The scheduled *block* deliberately captures nothing from here.
    nonisolated(unsafe) private static var activity: NSBackgroundActivityScheduler?

    /// What an OS-scheduled wake actually does.
    ///
    /// Registered rather than reached for. Everything that can refresh lives above this module,
    /// and on iOS the equivalent wiring is a `.backgroundTask` scene modifier in the app target —
    /// so this is the macOS shape of the same seam. Unset, ``schedule(after:)`` declines rather
    /// than registering an activity with nothing to run.
    nonisolated(unsafe) private static var operation: (@Sendable () async -> Void)?

    /// Declares what a background wake should do. Call once, at startup, before scheduling.
    public static func setOperation(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    private static func cancelActivity() {
        activity?.invalidate()
        activity = nil
    }
    #endif

    // MARK: - Diagnostics

    /// What has actually happened, for the settings screen to show.
    ///
    /// Recorded because background refresh is otherwise unfalsifiable from the outside. The system
    /// decides when — or whether — to run the task, gives no reason when it declines, and the run
    /// happens with the app off screen, so "it never refreshes in the background" and "it refreshes
    /// but hours apart" are the same observation. Neither the reader nor I can tell them apart by
    /// looking at the timeline. Two facts settle it: whether the request was accepted, and when the
    /// last run happened.
    ///
    /// `UserDefaults` rather than the store: a background launch has to write this before it has
    /// done anything else worth trusting, and it must survive the process being killed straight
    /// afterwards.
    public struct Diagnostics: Sendable, Equatable {

        /// When a background run last started, if ever.
        public var lastRunAt: Date?

        /// How many background runs have happened since the app was installed.
        public var runCount: Int

        /// Whether the last attempt to queue a request was accepted by the system.
        ///
        /// `false` is the interesting case and has ordinary causes — Background App Refresh off in
        /// Settings, Low Power Mode, or the simulator, which has no scheduler at all.
        public var isRequestQueued: Bool

        /// When a request was last accepted.
        public var lastScheduledAt: Date?

        public init(
            lastRunAt: Date? = nil,
            runCount: Int = 0,
            isRequestQueued: Bool = false,
            lastScheduledAt: Date? = nil
        ) {
            self.lastRunAt = lastRunAt
            self.runCount = runCount
            self.isRequestQueued = isRequestQueued
            self.lastScheduledAt = lastScheduledAt
        }
    }

    private enum Key {
        static let lastRunAt = "ReadRead.backgroundRefresh.lastRunAt"
        static let runCount = "ReadRead.backgroundRefresh.runCount"
        static let isQueued = "ReadRead.backgroundRefresh.isQueued"
        static let lastScheduledAt = "ReadRead.backgroundRefresh.lastScheduledAt"
    }

    /// Where the diary is kept. Overridable so a test does not write the real one.
    ///
    /// `nonisolated(unsafe)` because it is written once, by a test, before anything reads it. The
    /// alternative — an actor around four `UserDefaults` keys — would make the one caller that
    /// matters, a background launch recording that it ran, asynchronous for no benefit.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    public static var diagnostics: Diagnostics {
        Diagnostics(
            lastRunAt: defaults.object(forKey: Key.lastRunAt) as? Date,
            runCount: defaults.integer(forKey: Key.runCount),
            isRequestQueued: defaults.bool(forKey: Key.isQueued),
            lastScheduledAt: defaults.object(forKey: Key.lastScheduledAt) as? Date
        )
    }

    /// Records that a background run has begun.
    ///
    /// At the start rather than the end, deliberately: a run that the system cuts off partway is
    /// still evidence that background refresh is happening, and it is the case most worth telling
    /// apart from never running at all.
    ///
    /// One writer per platform, and they mean the same thing: the system chose this moment and
    /// woke the app for it. On iOS that is a `BGAppRefreshTask` launch; on macOS an
    /// `NSBackgroundActivityScheduler` block.
    ///
    /// It used to mean something weaker on the Mac — any feed cadence that happened to run while
    /// the app was not frontmost — because there was no scheduler there to record. That number
    /// answered a different question from the iOS one under the same label, which is worse than
    /// having no number.
    public static func recordRun(at date: Date = .now) {
        defaults.set(date, forKey: Key.lastRunAt)
        defaults.set(defaults.integer(forKey: Key.runCount) + 1, forKey: Key.runCount)
    }

    static func recordSchedule(accepted: Bool, at date: Date = .now) {
        defaults.set(accepted, forKey: Key.isQueued)
        if accepted { defaults.set(date, forKey: Key.lastScheduledAt) }
    }
}
