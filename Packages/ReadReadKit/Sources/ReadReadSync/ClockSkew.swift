import Foundation

/// What this device's clock looks like next to the sync server's.
///
/// ## Why this is measured at all
///
/// `EffectivePosition.reduce` orders positions by wall clock, and the clocks it compares belong to
/// different machines. `SyncStore.applyPosition` clamps a timestamp more than an hour in the
/// *future*, which stops a wildly wrong clock holding every scope hostage — and nothing bounds a
/// clock that is **behind**. A device whose clock has slipped writes positions that look older than
/// they are, loses the reduction to a genuinely older reading, and the reader is put back where
/// they were yesterday with nothing on screen to say why. "Position sync is flaky" is what that
/// looks like from the outside.
///
/// Ordering it properly means a logical clock — a counter per row, merged on every read, with a
/// schema change and a new rule in the one place this app has most carefully kept rule-free. That
/// is a large bill for a fault nobody has yet had. This is the cheap half: the server's `Date`
/// header is a reference both devices can be measured against, so a device that is wrong can at
/// least say so, in the one screen where sync is already explained.
///
/// It does not correct anything. Rewriting timestamps by an observed offset would mean this app
/// deciding whose clock is right, and it has no standing to: the server's own clock can be the
/// wrong one.
public enum ClockSkew {

    /// How far this device is ahead of the server, in seconds. Negative means behind.
    public static func seconds(localNow: Date, serverNow: Date) -> TimeInterval {
        localNow.timeIntervalSince(serverNow)
    }

    /// Past this, a skew is worth telling the reader about.
    ///
    /// Two minutes. Both platforms keep time from the network, so ordinary drift between a Mac and
    /// a phone is seconds and anything at this scale is a fault rather than drift. Low enough to be
    /// useful: a position is lost as soon as the error exceeds the gap between two readings, and
    /// for somebody moving between devices that gap is often a minute or two.
    public static let threshold: TimeInterval = 120

    public static func isWorthReporting(_ skew: TimeInterval) -> Bool {
        abs(skew) >= threshold
    }

    /// What the settings screen says about it, or `nil` when the clock is close enough.
    ///
    /// Built here rather than in the view because a sentence assembled from a number is exactly the
    /// shape that escapes translation when it is put together at the call site.
    ///
    /// The amount is formatted rather than interpolated as a bare figure, which also settles the
    /// plural: `Duration`'s unit style agrees in whatever language it is asked in, where inflection
    /// markup only works in `Text`'s literal overload and would be rendered verbatim by the time it
    /// reached the screen from here. One unit, so a skew of hours reads as hours — the exact figure
    /// is noise next to the fact that there is one.
    public static func warning(for skew: TimeInterval) -> String? {
        guard isWorthReporting(skew) else { return nil }
        let amount = Duration.seconds(abs(skew)).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1)
        )

        if skew < 0 {
            return String(localized: "This device's clock is about \(amount) behind the sync server. Reading positions are ordered by time, so this device can lose its place to an older one.")
        }
        return String(localized: "This device's clock is about \(amount) ahead of the sync server. Reading positions are ordered by time, so this device can hold a place it has already left.")
    }
}
