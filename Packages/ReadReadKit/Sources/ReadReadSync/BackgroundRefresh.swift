#if os(iOS)
import BackgroundTasks
import UIKit
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
    /// Read from the running bundle's own `BGTaskSchedulerPermittedIdentifiers`, because that list
    /// is what the system checks every `register` and `submit` against, so it is the only copy
    /// that cannot be wrong.
    ///
    /// It used to be derived from the bundle identifier, on the reasoning that `Info.plist` derives
    /// its entry the same way — `$(PRODUCT_BUNDLE_IDENTIFIER).refresh`. The two drifted: a build
    /// on a new phone ran as `com.kittmedia.ReadRead.QR2CW5GWB2`, with the team ID appended to the
    /// bundle identifier after the plist had already been expanded against the plain one. Every
    /// registration and every request then failed with `notPermitted`, for an identifier the
    /// build had never declared.
    public static var identifier: String {
        identifier(
            permitted: Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// The declared refresh identifier, falling back to the bundle-derived one only when the
    /// bundle declares none — a test host, or a build that has lost the key, where the request is
    /// refused either way and the log says why.
    ///
    /// One identifier for every install. An identifier matching a renamed bundle was tried for the
    /// Impactor case and changed nothing: the scheduler rejected that install's requests whatever
    /// they were called.
    static func identifier(permitted: [String]?, bundleIdentifier: String?) -> String {
        if let declared = permitted?.first(where: { $0.hasSuffix(".refresh") }) {
            return declared
        }
        return "\(bundleIdentifier ?? "com.kittmedia.ReadRead").refresh"
    }

    /// Asks the system to run a background refresh no sooner than `seconds` from now.
    ///
    /// On the main actor because a refusal is recorded with the system state that explains it —
    /// `UIApplication.backgroundRefreshStatus` and the app's own state — and both are main-actor
    /// reads. Every caller was on it already.
    ///
    /// - Parameters:
    ///   - seconds: from ``RefreshSettings/backgroundRefreshSeconds``. `nil` means every cadence
    ///     is switched off, which cancels any pending request rather than queueing one: a reader
    ///     who has turned refreshing off has turned it off everywhere.
    ///   - trigger: who asked, for the log. Five call sites submit the same request, and a refusal
    ///     from one of them only is a different problem from a refusal from all of them.
    /// - Returns: Whether a request is now queued.
    @MainActor
    @discardableResult
    public static func schedule(after seconds: Int?, trigger: Trigger) -> Bool {
        #if os(macOS)
        guard let seconds else {
            cancelActivity()
            recordRefusal(.cadencesOff, trigger: trigger)
            return false
        }
        guard let operation else {
            cancelActivity()
            recordRefusal(.unknown, trigger: trigger, detail: "No operation registered")
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
            let start = Date.now
            recordRun(at: start)
            // The block is handed a completion handler and must call it, or the activity is never
            // rescheduled. Bridged through a task because the work is `async`; the handler is
            // documented `Sendable` and may be called from anywhere.
            Task {
                await operation()
                recordRunEnded(startedAt: start, expired: false)
                completion(.finished)
            }
        }
        activity = scheduler
        recordSchedule(accepted: true)
        log(.scheduled, trigger: trigger, detail: "Every \(seconds) s")
        return true
        #elseif os(iOS)
        guard let seconds else {
            cancel()
            recordRefusal(.cadencesOff, trigger: trigger)
            return false
        }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // The earliest the system *may* run it, not when it will. It routinely waits far longer,
        // which is why the app must never treat a background run as its only refresh.
        let earliest = Date(timeIntervalSinceNow: TimeInterval(seconds))
        request.earliestBeginDate = earliest

        do {
            try BGTaskScheduler.shared.submit(request)
            recordSchedule(accepted: true)
            log(
                .scheduled,
                trigger: trigger,
                detail: "Not before \(earliest.ISO8601Format())"
            )
            // Checked straight after, because on a sideloaded phone every submit was accepted and
            // the settings screen still never found the request pending — an acceptance the
            // scheduler did not keep. Every identifier it holds, not only this one, so a request
            // filed under a different identity shows up too.
            Task {
                try? await Task.sleep(for: .seconds(2))
                let pending = await pendingIdentifiers()
                log(.pendingChecked, trigger: trigger, detail: "Pending: \(pending) · \(declaredConfiguration())")
            }
            return true
        } catch {
            // Refusals are ordinary and none of them are worth interrupting a reader for: the
            // simulator has no scheduler at all, and a device with Background App Refresh switched
            // off in Settings declines every request. The foreground cadences still work.
            //
            // Recorded rather than swallowed, though. A silently declined request and a request the
            // system simply has not chosen to run yet produce the identical symptom, and only one
            // of them has a fix the reader can apply.
            //
            // With the error's code and the system state beside it, because "declined" alone was
            // what the settings screen showed on a new phone whose Background App Refresh read as
            // on — and `BGTaskScheduler` has three different refusals behind that one word.
            let error = error as NSError
            recordRefusal(
                Refusal(error),
                trigger: trigger,
                detail: "\(error.domain) \(error.code): \(error.localizedDescription) · \(systemState()) · \(declaredConfiguration())"
            )
            return false
        }
        #else
        return false
        #endif
    }

    /// Who asked for a request, for the log.
    public enum Trigger: String, Codable, Sendable {
        case launch
        case activated
        case enteredBackground
        case backgroundRun
        case settingsChanged
        case statusChanged
        case retry
    }

    /// Why no request is queued.
    ///
    /// The `BGTaskScheduler` cases map its error codes one to one. They are worth telling apart
    /// because each has a different fix: `unavailable` is a setting on the device, `notPermitted`
    /// is a bug in this build's `Info.plist`, and `tooManyPendingRequests` is a bug in how often
    /// this code submits.
    public enum Refusal: String, Codable, Sendable {
        /// Every cadence is switched off, so nothing was asked for.
        case cadencesOff
        /// Background App Refresh is off, restricted or suspended by Low Power Mode — or this is
        /// the simulator.
        case unavailable
        case tooManyPendingRequests
        /// The identifier is not in `BGTaskSchedulerPermittedIdentifiers`.
        case notPermitted
        case unknown

        init(_ error: NSError) {
            #if os(iOS)
            if error.domain == BGTaskScheduler.errorDomain {
                switch BGTaskScheduler.Error.Code(rawValue: error.code) {
                case .unavailable: self = .unavailable
                case .tooManyPendingTaskRequests: self = .tooManyPendingRequests
                case .notPermitted: self = .notPermitted
                default: self = .unknown
                }
                return
            }
            #endif
            self = .unknown
        }
    }

    /// The system's own view of the request, which the diary can only infer.
    public struct PendingRequest: Sendable, Equatable {
        /// `nil` on the Mac, where an activity has an interval rather than a start date.
        public var earliestBeginDate: Date?
    }

    /// Asks the system whether a request is actually queued.
    ///
    /// The ground truth behind ``Diagnostics/isRequestQueued``, which only records what the last
    /// submit returned: a request accepted and then dropped — by a reinstall, a restore onto a new
    /// phone, or the system itself — still reads as queued in the diary.
    public static func pendingRequest() async -> PendingRequest? {
        #if os(iOS)
        let identifier = identifier
        return await withCheckedContinuation { continuation in
            // `@Sendable` spelled out: the scheduler calls back on a queue of its own, and a
            // closure inferred into the caller's isolation would trap there.
            BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
                let match = requests.first { $0.identifier == identifier }
                continuation.resume(returning: match.map {
                    PendingRequest(earliestBeginDate: $0.earliestBeginDate)
                })
            }
        }
        #elseif os(macOS)
        return activity == nil ? nil : PendingRequest(earliestBeginDate: nil)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// Every request the scheduler holds for this app, with its earliest start, for the log.
    static func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
                continuation.resume(returning: requests.map { request in
                    let start = request.earliestBeginDate?.ISO8601Format() ?? "any time"
                    return "\(request.identifier) (not before \(start))"
                })
            }
        }
    }

    /// Background App Refresh as the system reports it, right now.
    @MainActor
    public static var systemStatus: UIBackgroundRefreshStatus {
        UIApplication.shared.backgroundRefreshStatus
    }

    /// One line of the state a refusal or a run is best read against, for the log.
    ///
    /// English and unlocalised on purpose: it is evidence to be pasted into a bug report, not
    /// copy for the reader.
    @MainActor
    public static func systemState() -> String {
        let status = switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        let app = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        return "Background App Refresh: \(status), Low Power Mode: \(lowPower), app: \(app)"
    }
    #endif

    /// Drops any pending request.
    public static func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        #elseif os(macOS)
        cancelActivity()
        #endif
    }

    /// What an OS-scheduled wake actually does.
    ///
    /// Registered rather than reached for, because everything that can refresh lives above this
    /// module. On the Mac, ``schedule(after:)`` declines while it is unset rather than registering
    /// an activity with nothing to run; on iOS a launch with it unset completes the task at once.
    ///
    /// `nonisolated(unsafe)` for the same reason as ``defaults``: written once, at startup, before
    /// anything reads it.
    nonisolated(unsafe) private static var operation: (@Sendable () async -> Void)?

    /// Declares what a background wake should do. Call once, at startup, before scheduling — and
    /// on iOS before ``register()``, since a background launch can run the handler straight away.
    public static func setOperation(_ operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    #if os(iOS)
    /// Whether ``register()`` succeeded in this process, for the log.
    nonisolated(unsafe) private static var isRegistered = false

    /// Registers the launch handler with `BGTaskScheduler`. Call from
    /// `application(_:didFinishLaunchingWithOptions:)` — the system requires every permitted
    /// identifier to be registered before launch finishes.
    ///
    /// This used to be SwiftUI's `.backgroundTask(.appRefresh(_:))` scene modifier, which
    /// registers somewhere inside SwiftUI and reports nothing. A phone whose every submit then
    /// failed with `notPermitted` left no way to tell a missing declaration from a missing
    /// registration. Registered here, the answer is `register`'s return value, and it is logged
    /// beside what this process actually reads from its own `Info.plist`.
    @MainActor
    @discardableResult
    public static func register() -> Bool {
        // The main queue, so the handler runs where `handle(_:)` is isolated.
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated { handle(task) }
        }
        isRegistered = registered
        log(registered ? .registered : .registrationFailed, detail: declaredConfiguration())
        return registered
    }

    /// Runs one background launch and reports its end to the system.
    @MainActor
    private static func handle(_ task: BGTask) {
        guard let operation else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            await operation()
            // `success: false` when the system took the time back, so it knows the run fell
            // short. Called exactly once either way: expiry only cancels this task.
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // `@Sendable` spelled out: the system calls this from a queue of its own, and a closure
        // inferred into the main actor would trap there.
        task.expirationHandler = { @Sendable in work.cancel() }
    }

    /// What this process believes it declared: the identifier it asks for, and what its own
    /// `Info.plist` permits.
    ///
    /// Read from the running bundle rather than trusted from the build, because the build was
    /// checked and was right while the device reported `notPermitted` anyway.
    public static func declaredConfiguration() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let permitted = (info["BGTaskSchedulerPermittedIdentifiers"] as? [String]) ?? []
        let modes = (info["UIBackgroundModes"] as? [String]) ?? []
        let bundle = Bundle.main.bundleIdentifier ?? "none"
        return "Bundle: \(bundle), identifier: \(identifier), permitted: \(permitted), modes: \(modes), registered: \(isRegistered)"
    }
    #endif

    #if os(macOS)
    /// The activity currently registered, so a settings change replaces it rather than stacking
    /// another one behind it.
    ///
    /// `nonisolated(unsafe)` for the same reason as ``defaults``: it is touched from the main actor
    /// only — ``schedule(after:)`` and ``cancel()`` are both called from `AppServices` — and the
    /// alternative, an actor around one object, would make a scheduling call asynchronous for no
    /// benefit. The scheduled *block* deliberately captures nothing from here.
    nonisolated(unsafe) private static var activity: NSBackgroundActivityScheduler?

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

        /// Why the last attempt was declined, while it still stands. Cleared by an acceptance.
        public var refusal: Refusal?

        /// The error and the system state at the time of ``refusal``, verbatim.
        public var refusalDetail: String?

        /// The most recent events, newest first. See ``LogEntry``.
        public var log: [LogEntry]

        public init(
            lastRunAt: Date? = nil,
            runCount: Int = 0,
            isRequestQueued: Bool = false,
            lastScheduledAt: Date? = nil,
            refusal: Refusal? = nil,
            refusalDetail: String? = nil,
            log: [LogEntry] = []
        ) {
            self.lastRunAt = lastRunAt
            self.runCount = runCount
            self.isRequestQueued = isRequestQueued
            self.lastScheduledAt = lastScheduledAt
            self.refusal = refusal
            self.refusalDetail = refusalDetail
            self.log = log
        }
    }

    /// One thing that happened to background refreshing.
    ///
    /// The diary above keeps only the latest of each fact, which cannot answer the questions a
    /// refresh that never comes raises: was a request accepted and then never run, or accepted at
    /// launch and declined on the way out, or did the runs happen and get cut off each time? A
    /// short history can.
    public struct LogEntry: Codable, Sendable, Equatable, Identifiable {
        public enum Event: String, Codable, Sendable {
            case scheduled
            case declined
            case runStarted
            case runFinished
            case runExpired
            case statusChanged
            case registered
            case registrationFailed
            case pendingChecked
        }

        public var id: UUID
        public var date: Date
        public var event: Event
        public var trigger: Trigger?
        /// Verbatim and unlocalised: evidence, not copy.
        public var detail: String?

        public init(
            id: UUID = UUID(),
            date: Date,
            event: Event,
            trigger: Trigger? = nil,
            detail: String? = nil
        ) {
            self.id = id
            self.date = date
            self.event = event
            self.trigger = trigger
            self.detail = detail
        }
    }

    /// How many entries the log keeps. A few days of ordinary use, which is the span a "it never
    /// refreshes" report covers.
    static let logLimit = 100

    private enum Key {
        static let lastRunAt = "ReadRead.backgroundRefresh.lastRunAt"
        static let runCount = "ReadRead.backgroundRefresh.runCount"
        static let isQueued = "ReadRead.backgroundRefresh.isQueued"
        static let lastScheduledAt = "ReadRead.backgroundRefresh.lastScheduledAt"
        static let refusal = "ReadRead.backgroundRefresh.refusal"
        static let refusalDetail = "ReadRead.backgroundRefresh.refusalDetail"
        static let log = "ReadRead.backgroundRefresh.log"
    }

    /// Serialises the log's read-modify-write. The macOS activity block records its run from a
    /// queue of the system's choosing while the main actor may be logging a schedule.
    private static let logLock = NSLock()

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
            lastScheduledAt: defaults.object(forKey: Key.lastScheduledAt) as? Date,
            refusal: defaults.string(forKey: Key.refusal).flatMap(Refusal.init(rawValue:)),
            refusalDetail: defaults.string(forKey: Key.refusalDetail),
            log: storedLog()
        )
    }

    /// Appends one entry to the log, dropping the oldest past ``logLimit``.
    public static func log(
        _ event: LogEntry.Event,
        trigger: Trigger? = nil,
        detail: String? = nil,
        at date: Date = .now
    ) {
        logLock.withLock {
            var entries = storedLog()
            entries.insert(LogEntry(date: date, event: event, trigger: trigger, detail: detail), at: 0)
            if entries.count > logLimit { entries.removeLast(entries.count - logLimit) }
            // A log that fails to encode is dropped rather than half-written: it is a debugging
            // aid, and nothing in it is worth an error path.
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Key.log)
            }
        }
    }

    /// The log as a block of text, for sharing into a bug report.
    public static func logText(_ entries: [LogEntry]) -> String {
        entries.map { entry in
            [
                entry.date.ISO8601Format(),
                entry.event.rawValue,
                entry.trigger.map { "(\($0.rawValue))" },
                entry.detail,
            ]
            .compactMap(\.self)
            .joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func storedLog() -> [LogEntry] {
        guard let data = defaults.data(forKey: Key.log) else { return [] }
        return (try? JSONDecoder().decode([LogEntry].self, from: data)) ?? []
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
    public static func recordRun(at date: Date = .now, detail: String? = nil) {
        defaults.set(date, forKey: Key.lastRunAt)
        defaults.set(defaults.integer(forKey: Key.runCount) + 1, forKey: Key.runCount)
        log(.runStarted, detail: detail, at: date)
    }

    /// Records how a run ended. `expired` is the system taking its time back before the work was
    /// done — the case that looks like success from every other angle.
    public static func recordRunEnded(startedAt start: Date, expired: Bool, at date: Date = .now) {
        // POSIX formatting, like the rest of a detail: evidence reads the same on every device.
        let seconds = String(format: "%.1f", date.timeIntervalSince(start))
        log(expired ? .runExpired : .runFinished, detail: "After \(seconds) s", at: date)
    }

    static func recordSchedule(accepted: Bool, at date: Date = .now) {
        defaults.set(accepted, forKey: Key.isQueued)
        if accepted {
            defaults.set(date, forKey: Key.lastScheduledAt)
            defaults.removeObject(forKey: Key.refusal)
            defaults.removeObject(forKey: Key.refusalDetail)
        }
    }

    static func recordRefusal(
        _ refusal: Refusal,
        trigger: Trigger,
        detail: String? = nil,
        at date: Date = .now
    ) {
        recordSchedule(accepted: false, at: date)
        defaults.set(refusal.rawValue, forKey: Key.refusal)
        if let detail {
            defaults.set(detail, forKey: Key.refusalDetail)
        } else {
            defaults.removeObject(forKey: Key.refusalDetail)
        }
        log(
            .declined,
            trigger: trigger,
            detail: [refusal.rawValue, detail].compactMap(\.self).joined(separator: " · "),
            at: date
        )
    }
}
