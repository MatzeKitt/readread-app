import Foundation
import Observation
import SwiftUI

/// A shared "now" that steps on the minute, so timestamps already on screen keep telling the truth.
///
/// A relative date is formatted once, when the view holding it is built, and then never again — so
/// a list left open says "2m" about a post that is now an hour old. That is worse than a merely
/// stale label: the timestamp is what a reader uses to orient themselves in the timeline, so it is
/// the one thing in the row that must not quietly stop being a fact.
///
/// One clock for the window rather than a timer per row, which matters twice. Every timestamp on
/// screen turns over at the same moment, which a row that started its own timer when it happened to
/// scroll into view cannot promise; and a list scrolling past hundreds of rows is not creating and
/// cancelling a timer for each of them.
///
/// It is read from the *smallest* view that depends on it — see ``RelativeTimestamp`` — and never
/// from the row. Observation takes its dependency wherever the value is read, so reading it in
/// ``ItemRow`` would rebuild that row's whole body, media strip and link card included, once a
/// minute for a change of at most two characters.
@MainActor
@Observable
final class RelativeClock {

    /// How long a step is.
    ///
    /// A minute, because that is the resolution the label has: an abbreviated relative date cannot
    /// be wrong by less than a minute once it is past its first one, so stepping more often would
    /// be redrawing in order to print the same string. The cost is that an item's first minute
    /// reads as however old it was when the row was built, which is the one case this deliberately
    /// does not chase.
    nonisolated static let step: TimeInterval = 60

    /// The moment every relative timestamp is measured against.
    private(set) var now: Date

    init(now: Date = .now) {
        self.now = now
    }

    /// Steps the clock until the task driving it is cancelled.
    ///
    /// `Task.sleep` rather than a `Timer`, so the loop is owned by the view that started it and
    /// there is nothing to invalidate by hand. The sleep is against the continuous clock, which
    /// keeps running while iOS has the app suspended — and the first thing the loop does on the far
    /// side of it is read the *wall* clock, so an app returning after an hour away is correct
    /// immediately rather than an hour behind.
    ///
    /// Not paused behind a hidden window, unlike the refresh timers in `AppServices`: those spend a
    /// network request on nobody, where this assigns a `Date` once a minute and invalidates only
    /// the timestamps that are actually on screen. Pausing it would be lifecycle plumbing bought
    /// with a risk of a window coming back with frozen dates.
    func run() async {
        while !Task.isCancelled {
            now = .now
            do {
                try await Task.sleep(for: .seconds(Self.interval(afterTickAt: now)))
            } catch {
                return
            }
        }
    }

    /// How long to wait after a step taken at `date`.
    ///
    /// Aligned to the wall clock rather than counted from the previous step, so every timestamp in
    /// the window turns over together, and so a clock started at 12:00:59 does not spend the rest of
    /// the session a second behind the minute it is displaying.
    ///
    /// The answer is always in `(0, step]` — never zero, which is what stops ``run()`` spinning on a
    /// step that lands exactly on the boundary.
    ///
    /// `nonisolated` because it is arithmetic over its arguments and touches nothing else. Left on
    /// the main actor with the rest of the class it could only be asserted from a main-actor test,
    /// which is a hop bought for nothing.
    nonisolated static func interval(
        afterTickAt date: Date,
        step: TimeInterval = RelativeClock.step
    ) -> TimeInterval {
        let elapsed = date.timeIntervalSinceReferenceDate
        let remainder = elapsed.truncatingRemainder(dividingBy: step)
        // `truncatingRemainder` keeps the sign of its left operand, so a date before the reference
        // epoch would otherwise be handed a wait of more than a whole step.
        return step - (remainder < 0 ? remainder + step : remainder)
    }
}

/// A relative timestamp that keeps up with the clock.
///
/// Its own view, and that is the entire point of it: it is the only thing in a row that depends on
/// the current time, so it is the only thing that should be rebuilt when the time changes. See
/// ``RelativeClock``.
struct RelativeTimestamp: View {

    let date: Date

    /// Optional so the view works — and previews — without a clock installed, in which case it
    /// formats against the moment it was built, which is exactly the behaviour it replaces.
    @Environment(RelativeClock.self) private var clock: RelativeClock?

    var body: some View {
        // Measured against the clock's value rather than against `Date.now`, which is what makes
        // what is on screen a function of the clock instead of leaving the clock as a redraw
        // trigger whose value nothing reads.
        let now = clock?.now ?? .now

        // Note which date goes where: `now` is the value being formatted and the *item's* date is
        // the style's anchor. See ``style(for:unitsStyle:)`` — that is not the way round it looks.
        Text(now, format: Self.style(for: date, unitsStyle: .abbreviated))
            // Narrow is right on the screen and wrong out loud: VoiceOver reads the abbreviation
            // itself, so a post two hours old was announced as "2h". The wide style is the same
            // fact spelled out, and costs nothing visually because it is never drawn.
            .accessibilityLabel(Text(now, format: Self.style(for: date, unitsStyle: .wide)))
    }

    /// The style that describes `date` from wherever the reader is in time.
    ///
    /// **The item's date is the anchor, and the date handed to `format(_:)` is the present.** That
    /// reads backwards and is not a slip: `Date.AnchoredRelativeFormatStyle` describes its *anchor*
    /// from the perspective of the value it is given, which is the opposite way round from the
    /// parameter names. Anchored on the present and asked to format the item — the arrangement the
    /// names suggest — it printed "in 55 min." for a post published 55 minutes ago, and a whole
    /// timeline appeared to be arriving from the future.
    ///
    /// Written as a function rather than inline, because that direction is the one thing here worth
    /// pinning down: `RelativeTimestampTests` asserts both the sense of it and that it agrees
    /// string for string with `Date.RelativeFormatStyle`, which is what the rows drew before they
    /// learned to age. So an OS that one day corrects the anchor's sense fails a test rather than a
    /// timeline.
    ///
    /// Returned as a style rather than a formatted `String` so SwiftUI applies the view's own
    /// `\.locale` to it, the way `Text(_:format:)` always has.
    nonisolated static func style(
        for date: Date,
        unitsStyle: Date.RelativeFormatStyle.UnitsStyle
    ) -> Date.AnchoredRelativeFormatStyle {
        Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .numeric, unitsStyle: unitsStyle)
    }
}
