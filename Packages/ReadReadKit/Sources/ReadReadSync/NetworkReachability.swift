import Foundation
import Network

/// Reports when the network comes back.
///
/// Worth having because the most common reason a refresh fails is that there was no network, and
/// the most useful moment to retry is the instant there is one. Waiting for the next timer tick
/// instead means the timeline stays stale for up to an hour after the user rejoins Wi-Fi.
public actor NetworkReachability {

    private let monitor: NWPathMonitor
    private var isStarted = false

    /// Last known state. Assumed satisfied until told otherwise, so a refresh is never suppressed
    /// merely because the monitor has not reported yet.
    private var isSatisfied = true

    /// Notified when connectivity is regained — not on every path change, since only the
    /// unavailable-to-available transition is worth acting on.
    private var onRestored: (@Sendable () async -> Void)?

    public init() {
        monitor = NWPathMonitor()
    }

    public var isCurrentlySatisfied: Bool { isSatisfied }

    public func start(onRestored: @escaping @Sendable () async -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.onRestored = onRestored

        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.handle(isSatisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "media.kitt.readread.reachability"))
    }

    public func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
        onRestored = nil
    }

    private func handle(isSatisfied satisfied: Bool) async {
        let wasSatisfied = isSatisfied
        isSatisfied = satisfied

        // Only the transition matters. Firing on every path update would refresh repeatedly while
        // roaming between networks, which is exactly when bandwidth is worth conserving.
        guard satisfied, !wasSatisfied, let onRestored else { return }
        await onRestored()
    }
}
