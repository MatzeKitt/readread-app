import Foundation
import ReadReadModel

/// What one refresh cycle achieved, from the badge's point of view.
public struct RefreshRunReport: Sendable, Equatable {

    /// Whether every ingest section completed — the walk reached its stop line or the end of the
    /// stream, rather than running out of pages or time.
    public var ingestComplete: Bool

    /// Whether the position sync succeeded.
    public var syncSucceeded: Bool

    /// Whether this cycle ingested items at all. A cycle that only refreshed positions has not
    /// established a new item count, so it must not publish one.
    public var didIngestItems: Bool

    public init(ingestComplete: Bool, syncSucceeded: Bool, didIngestItems: Bool = true) {
        self.ingestComplete = ingestComplete
        self.syncSucceeded = syncSucceeded
        self.didIngestItems = didIngestItems
    }

    /// Whether the store now holds a count worth showing.
    ///
    /// Both halves are required because the badge is a function of items **and** position: fresh
    /// items against a stale marker over-counts, a fresh marker against stale items under-counts.
    public var isConsistent: Bool {
        ingestComplete && syncSucceeded && didIngestItems
    }
}

/// Writes the app icon badge, but only from a consistent snapshot.
///
/// ## Why this is gated
///
/// Publishing after every ingest page is the obvious implementation and it is wrong in two ways,
/// both silent:
///
/// - **A partial ingest under-counts.** A run cut short by the background time budget leaves a
///   *lower* number, so the badge reads "3" while forty items wait. Wrong in the direction that
///   makes the user stop looking.
/// - **Half a refresh is not a snapshot.** The count depends on items and on the reading position,
///   and those arrive from different servers.
///
/// Gating also removes flicker: the count steps once per completed cycle instead of climbing
/// 3 → 17 → 42 as pages land.
///
/// The in-app counts are deliberately **not** gated — see `ThresholdCounts`. In the foreground,
/// watching items arrive is the point; the badge is the glanceable signal seen when the app is
/// closed, so it waits for something it can be trusted on.
public actor BadgePublisher {

    /// Sets the platform badge. Injected so the gating logic is testable without notification
    /// authorisation or a running app.
    public typealias Setter = @Sendable (Int) async throws -> Void

    private let setBadge: Setter

    /// Last value actually written. Retained across skipped runs, so an interrupted cycle leaves
    /// the previous good number in place rather than blanking it.
    private var published: Int?

    /// Counts computed but withheld, for diagnostics in the settings screen.
    private(set) public var withheldCount: Int?

    public init(setBadge: @escaping Setter) {
        self.setBadge = setBadge
    }

    public var lastPublishedCount: Int? { published }

    /// Publishes `count` if the cycle was consistent.
    ///
    /// - Returns: `true` if the badge was written.
    @discardableResult
    public func publish(count: Int, report: RefreshRunReport) async -> Bool {
        guard report.isConsistent else {
            withheldCount = count
            return false
        }

        // Skip a redundant write. Setting the same value repeatedly is harmless but it is also a
        // cross-process call on every cycle for no effect.
        guard count != published else {
            withheldCount = nil
            return false
        }

        do {
            try await setBadge(count)
            published = count
            withheldCount = nil
            return true
        } catch {
            // Badge authorisation can be refused, and on iOS that is a normal user choice rather
            // than an error worth surfacing anywhere.
            return false
        }
    }

    /// Publishes a count that changed because the reader moved, not because items arrived.
    ///
    /// The gate on ``publish(count:report:)`` exists because half an ingest is a partial *item
    /// set*. A position change has no equivalent failure: there is no half a scroll. The item set
    /// is whatever the last completed cycle established, and this replaces only the other half of
    /// the snapshot — the marker — with a newer, authoritative one. So the number it computes is
    /// at least as correct as the one already on the icon.
    ///
    /// Without it the badge ignores the single most frequent cause of the count changing. Reading
    /// forty items would leave `40` on the icon for up to fifteen minutes, until an unrelated feed
    /// refresh happened to run — and a badge that contradicts the app it is attached to is worse
    /// than no badge.
    ///
    /// Refuses until something has been published from a consistent snapshot. Before that there is
    /// no trustworthy item set to combine a position with, and starting from a partial one would
    /// publish an under-count that nothing would correct until the next completed cycle.
    ///
    /// - Returns: `true` if the badge was written.
    @discardableResult
    public func publishPositionChange(count: Int) async -> Bool {
        guard published != nil, count != published else { return false }

        do {
            try await setBadge(count)
            published = count
            withheldCount = nil
            return true
        } catch {
            return false
        }
    }

    /// Clears the badge, for sign-out.
    public func clear() async {
        try? await setBadge(0)
        published = 0
        withheldCount = nil
    }
}
