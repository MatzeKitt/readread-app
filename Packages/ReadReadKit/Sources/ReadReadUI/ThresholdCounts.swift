import Foundation
import Observation
import ReadReadModel
import SwiftData

/// Holds the "newer than the threshold" count for every visible scope.
///
/// ## Why this is one object rather than a `@Query` per row
///
/// The obvious approach is a small view per sidebar row with its own `@Query` for the count. That
/// works, but it means every insert during ingest re-runs one query per row, and SwiftUI has to
/// diff every row on each. Recomputing the whole map in a single batch, debounced, keeps the cost
/// proportional to a refresh rather than to rows × changes.
///
/// It also puts the counts somewhere the badge can read them, which a per-row `@Query` cannot do.
@MainActor
@Observable
public final class ThresholdCounts {

    /// Count of items newer than each scope's marker.
    public private(set) var newer: [ScopeID: Int] = [:]

    /// Count of items that arrived carrying a date below the marker, surfaced separately.
    public private(set) var lateArrivals: [ScopeID: Int] = [:]

    /// Scopes to keep counts for. Set by the sidebar as its tree changes.
    private var trackedScopes: Set<ScopeID> = []

    /// The scope the open timeline is reporting a live count for, and that count.
    ///
    /// Held as a single pair rather than a dictionary on purpose: there is only ever one timeline
    /// on screen, so a second entry could only be a leftover. A dictionary would let a scope keep
    /// reporting a count long after its list went away, pinning that badge to a stale number with
    /// nothing to correct it.
    private var liveScope: ScopeID?
    private var liveCount: Int?

    private var refreshTask: Task<Void, Never>?

    /// The main context, held rather than captured in the notification closure — capturing a
    /// non-`Sendable` `ModelContext` in a `@Sendable` block is not legal under strict concurrency.
    private var context: ModelContext?

    /// Owns the notification registration.
    ///
    /// A separate object because unregistering has to happen in a `deinit`, and a `@MainActor`
    /// class's `deinit` is nonisolated — so it cannot touch this class's own state. Marking the
    /// token `nonisolated` is not an option either: `@Observable` rewrites stored properties into
    /// generated accessors, which `nonisolated` cannot be applied to. Giving the registration its
    /// own unisolated lifetime sidesteps both problems.
    @ObservationIgnored private let registration = NotificationRegistration()

    public init() {}

    /// The count to show beside a scope.
    ///
    /// Prefers the open timeline's live figure over the stored one. The stored count only changes
    /// when the debounced position write lands, so without this the sidebar badge trailed the
    /// number above the list by about a second and a half — two readings of the same thing,
    /// visibly disagreeing.
    public func newerCount(for scope: ScopeID) -> Int {
        if scope == liveScope, let liveCount { return liveCount }
        return newer[scope] ?? 0
    }

    /// Reports what the open timeline is showing right now, ahead of the debounced write.
    ///
    /// Pass `nil` when the list goes away, so the badge falls back to the stored position.
    public func reportLiveCount(_ count: Int?, for scope: ScopeID) {
        // Guarded because this is called from a scroll callback: assigning an unchanged value
        // would still notify observers and rebuild the sidebar on every scroll event.
        guard liveScope != scope || liveCount != count else { return }
        liveScope = count == nil ? nil : scope
        liveCount = count
    }

    /// Drops the live count if `scope` still owns it.
    ///
    /// Conditional so that a list disappearing *after* its replacement has already reported cannot
    /// wipe the new scope's count.
    public func clearLiveCount(for scope: ScopeID) {
        guard liveScope == scope else { return }
        liveScope = nil
        liveCount = nil
    }

    public func lateArrivalCount(for scope: ScopeID) -> Int {
        lateArrivals[scope] ?? 0
    }

    /// Declares which scopes need counts, refreshing if the set changed.
    public func track(_ scopes: some Sequence<ScopeID>, in context: ModelContext) {
        let updated = Set(scopes)
        guard updated != trackedScopes else { return }
        trackedScopes = updated
        refresh(in: context)
    }

    /// Recomputes every tracked count.
    ///
    /// Synchronous against the context it is handed. Counts are `fetchCount` queries answered from
    /// an index, so even a hundred of them stay well inside a frame; making this asynchronous would
    /// add a hop and a stale-read window for no measurable gain.
    public func refresh(in context: ModelContext) {
        var newerCounts: [ScopeID: Int] = [:]
        var lateCounts: [ScopeID: Int] = [:]

        for scope in trackedScopes {
            do {
                newerCounts[scope] = try ThresholdService.newerCount(for: scope, in: context)
                lateCounts[scope] = try ThresholdService.lateArrivalCount(for: scope, in: context)
            } catch {
                // A failed count must not blank the sidebar. Carry the previous value forward: a
                // slightly stale number is far less confusing than a badge that flickers to zero.
                newerCounts[scope] = newer[scope] ?? 0
                lateCounts[scope] = lateArrivals[scope] ?? 0
            }
        }

        newer = newerCounts
        lateArrivals = lateCounts
    }

    /// Recomputes after a short delay, collapsing bursts.
    ///
    /// Ingest saves once per section, and a section is up to a hundred items. Without coalescing,
    /// a multi-page refresh would recompute every count several times per second.
    public func refreshDebounced(after delay: Duration = .milliseconds(200)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let context else { return }
            refresh(in: context)
        }
    }

    /// Starts recomputing whenever the store is saved.
    ///
    /// Observing saves rather than having each mutation site remember to call `refresh`: a count
    /// that silently stops updating because one new call site forgot to notify is a hard bug to
    /// notice and an easy one to introduce.
    public func startObserving(context: ModelContext) {
        guard !registration.isRegistered else { return }
        self.context = context

        registration.observe(ModelContext.didSave) { [weak self] in
            self?.refreshDebounced()
        }

        refresh(in: context)
    }
}

/// Owns one `NotificationCenter` block registration and unregisters it on deallocation.
///
/// Exists so an observer can be torn down from a `deinit` without that `deinit` needing to be
/// actor-isolated. This type has no isolation of its own, so its `deinit` may touch its own state
/// freely, while the callback it invokes hops to the main actor.
final class NotificationRegistration {

    private var observers: [any NSObjectProtocol] = []

    var isRegistered: Bool { !observers.isEmpty }

    /// Registers `handler`, delivered on the main actor.
    func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { _ in
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

    /// Registers `handler` for delivery in the same run-loop turn the notification is posted in.
    ///
    /// For the notifications where a turn is too late. ``observe(_:handler:)`` hops onto the main
    /// actor, which costs a turn of the run loop — and a turn of the run loop is a drawn frame. A
    /// view geometry correction applied a frame after the geometry changed is visible as a twitch,
    /// which is the whole thing `ScrollAnchor` exists to remove.
    ///
    /// The trade is that the handler runs only when the notification arrives on the main thread,
    /// and is **skipped** otherwise. Sound for AppKit and UIKit view notifications, which are
    /// posted from the main thread; not a general substitute for the hop. Asserting into the actor
    /// instead is not an option — `MainActor.assumeIsolated` off the main thread is a `SIGTRAP`
    /// rather than an error, which is documented above in painful detail.
    ///
    /// - Parameter object: Scoped deliberately. These are high-frequency notifications, and
    ///   `nil` would deliver every one in the process.
    func observeSynchronously(
        _ name: Notification.Name,
        object: AnyObject?,
        handler: @escaping @MainActor () -> Void
    ) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: nil
        ) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { handler() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
