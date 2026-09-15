import Foundation
import Testing

@testable import ReadReadUI

/// The scheduling behind the ageing timestamps in the lists.
///
/// Only the arithmetic is asserted here, and that is the part worth asserting: a wait of zero spins
/// the loop on the main actor, and a wait counted from the previous step instead of from the wall
/// clock drifts until the rows turn over at a different moment from every other clock on the screen.
/// Whether the label then reads "2m" is Foundation's business, and whether it redraws is something
/// only the running app can show.
@Suite("RelativeClock")
struct RelativeClockTests {

    /// Reference date plus this many seconds lands on a whole minute.
    private func date(secondsIntoMinute seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 600 + seconds)
    }

    @Test("A step taken mid-minute waits only for the rest of it")
    func waitsForTheRestOfTheMinute() {
        #expect(RelativeClock.interval(afterTickAt: date(secondsIntoMinute: 12)) == 48)
        #expect(RelativeClock.interval(afterTickAt: date(secondsIntoMinute: 59.5)) == 0.5)
    }

    /// Never zero, or ``RelativeClock/run()`` would sleep for nothing and step again immediately,
    /// for as long as the window stayed open.
    @Test("A step landing exactly on the minute waits a whole one")
    func waitsAFullStepOnTheBoundary() {
        #expect(RelativeClock.interval(afterTickAt: date(secondsIntoMinute: 0)) == 60)
    }

    /// The property the loop actually depends on, over a whole step's worth of starting points.
    @Test("The wait is always positive and never longer than a step")
    func waitIsBounded() {
        for offset in stride(from: 0.0, to: 60.0, by: 0.25) {
            let wait = RelativeClock.interval(afterTickAt: date(secondsIntoMinute: offset))
            #expect(wait > 0)
            #expect(wait <= RelativeClock.step)
        }
    }

    /// Two clocks started at different moments must agree about *when* to step, or the timestamps
    /// in two columns of the same window turn over seconds apart.
    @Test("Steps land on the wall clock, not on when the clock started")
    func stepsAlignToTheWallClock() {
        let early = date(secondsIntoMinute: 3)
        let late = date(secondsIntoMinute: 41)

        #expect(
            early.addingTimeInterval(RelativeClock.interval(afterTickAt: early))
                == late.addingTimeInterval(RelativeClock.interval(afterTickAt: late))
        )
    }

    /// `truncatingRemainder` keeps the sign of its left operand, so a date before the reference
    /// epoch would otherwise be handed a wait of more than a whole step — and the clock would stop
    /// stepping on the minute for the rest of the session.
    @Test("A date before the reference epoch still waits forward")
    func handlesDatesBeforeTheReferenceEpoch() {
        let wait = RelativeClock.interval(afterTickAt: Date(timeIntervalSinceReferenceDate: -12))
        #expect(wait == 12)
    }

    @MainActor
    @Test("A clock starts at the moment it was given")
    func startsAtItsGivenMoment() {
        let start = date(secondsIntoMinute: 7)
        #expect(RelativeClock(now: start).now == start)
    }
}
