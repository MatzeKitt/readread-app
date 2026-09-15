import Foundation
import SwiftData

/// One device's record of where it is reading in one scope.
///
/// ## What a position is
///
/// It is the item at the **fold** — the top of the viewport — and nothing more. The count beside a
/// scope is how many items sit above it, so scrolling down raises that count and scrolling up
/// lowers it. There is no notion of an item being "read": a position is a place, and it moves in
/// whichever direction the reader does.
///
/// This is deliberately *not* a high-water mark. That was the first design, and it could not
/// express the count: once you had been to the top, scrolling back down still reported "up to date"
/// even though items were now above the fold again.
///
/// ## Why this is per-device
///
/// A device only ever writes the row matching its own `deviceID`, so concurrent edits on two
/// devices touch disjoint rows and **cannot conflict** — which is what allows the sync server to be
/// a dumb blob store with no merge logic at all. The cost is a row per (scope, device) pair, which
/// is negligible: a handful of devices times a few dozen scopes.
@Model
public final class PositionMark {

    /// `"<scopeID>|<deviceID>"`. Stored as one field so it can carry the uniqueness constraint,
    /// and so it doubles as the sync record id.
    #Unique<PositionMark>([\.key])
    public var key: String = ""

    /// `ScopeID.rawValue`.
    public var scopeRaw: String = ScopeID.all.rawValue

    public var deviceID: String = ""

    /// `SortKey.rawValue` of the item at the fold. Everything strictly greater sits above it and
    /// is counted.
    public var markSortKeyRaw: String = SortKey.distantPast.rawValue

    /// When this row was last written.
    ///
    /// Load-bearing, not diagnostic: it is how rows from different devices are ordered, because
    /// the position that should win is simply the most recent one. See ``EffectivePosition``.
    public var updatedAt: Date = Date.now

    public init(
        scope: ScopeID,
        deviceID: String,
        markSortKey: SortKey = .distantPast,
        updatedAt: Date = .now
    ) {
        key = Self.key(scope: scope, deviceID: deviceID)
        scopeRaw = scope.rawValue
        self.deviceID = deviceID
        markSortKeyRaw = markSortKey.rawValue
        self.updatedAt = updatedAt
    }

    public static func key(scope: ScopeID, deviceID: String) -> String {
        "\(scope.rawValue)|\(deviceID)"
    }

    public var scope: ScopeID {
        ScopeID(rawValue: scopeRaw) ?? .all
    }

    public var markSortKey: SortKey {
        get { SortKey(rawValue: markSortKeyRaw) }
        set { markSortKeyRaw = newValue.rawValue }
    }
}

/// The position for a scope after reducing every device's row.
public struct EffectivePosition: Hashable, Sendable {

    public var scope: ScopeID
    public var markSortKey: SortKey

    /// When the winning row was written. Carried so callers can tell a real position from the
    /// default one, and so a device can recognise its own write coming back.
    public var updatedAt: Date

    /// Which device wrote the winning row, or `nil` when no device has.
    ///
    /// The open timeline needs this to answer one question: is the position on screen still mine?
    /// Comparing timestamps cannot answer it — a device's own row is written on every settled
    /// scroll, so "newer than mine" and "not mine" are the same test only until the clocks
    /// disagree. Without it a position arriving from another device changed the count and left the
    /// list where it was, which is what "position syncing doesn't work" looks like from outside.
    public var deviceID: String?

    public init(
        scope: ScopeID,
        markSortKey: SortKey,
        updatedAt: Date = .distantPast,
        deviceID: String? = nil
    ) {
        self.scope = scope
        self.markSortKey = markSortKey
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    /// A scope no device has a position in: the marker sits below every item, so everything counts.
    public static func unread(_ scope: ScopeID) -> EffectivePosition {
        EffectivePosition(scope: scope, markSortKey: .distantPast)
    }

    /// Reduces per-device rows into the one position the UI should use.
    ///
    /// **The most recently written row wins.** A position is where the reader is, so the newest
    /// report of it is the truth: writing your own row makes your own device authoritative
    /// immediately, which is what lets the count follow your scrolling live, while a device you
    /// pick up later adopts wherever you last were.
    ///
    /// The earlier design took the *furthest* position instead, with a generation counter so a
    /// deliberate move backwards could beat it. Both are gone: furthest-wins would pin the count
    /// to whichever device had scrolled deepest, and once positions move freely there is nothing
    /// for a generation to override.
    ///
    /// Ties break on `deviceID` purely so the result does not depend on the order rows are fed in.
    /// The ordering is wall-clock, so a device with a badly wrong clock could hold the position
    /// until it is next used; `SyncStore` clamps absurd future timestamps on the way in to bound
    /// that. It is the accepted cost of resolving this on the client, where merges have to happen
    /// before anything is pushed.
    public static func reduce(
        _ marks: some Sequence<(deviceID: String, markSortKey: SortKey, updatedAt: Date)>,
        scope: ScopeID
    ) -> EffectivePosition {
        var winner: (deviceID: String, markSortKey: SortKey, updatedAt: Date)?

        for mark in marks {
            guard let current = winner else {
                winner = mark
                continue
            }
            if mark.updatedAt > current.updatedAt
                || (mark.updatedAt == current.updatedAt && mark.deviceID > current.deviceID) {
                winner = mark
            }
        }

        guard let winner else { return .unread(scope) }
        return EffectivePosition(
            scope: scope,
            markSortKey: winner.markSortKey,
            updatedAt: winner.updatedAt,
            deviceID: winner.deviceID
        )
    }
}
