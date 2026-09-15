import Testing

@testable import ReadReadUI

/// When a settled scroll counts as settled.
///
/// Tested because this cost a reading position once already. The rule — a second and a half of
/// quiet after the last scroll — was implemented as "sleep a second and a half, and if the scroll
/// is more recent than that, sleep a second and a half again", which is a different rule that
/// looks the same in the code and nearly doubles the wait. The write it delays lives in a `.task`,
/// and a `.task` dies when its view disappears, so the extra wait was long enough to lose the
/// position outright when a reader scrolled and immediately opened an item.
@Suite("Position debounce")
struct PositionDebounceTests {

    private let delay = Duration.milliseconds(1_500)

    /// The case that was the bug: a fold that changed shortly before the scroll ended, so most of
    /// the delay has already been slept and only the remainder is owed.
    @Test("A partly-elapsed delay is topped up, not restarted")
    func partlyElapsedIsToppedUp() {
        let remaining = PositionDebounce.remainingQuiet(
            sinceLastScroll: .milliseconds(1_300),
            delay: delay
        )

        #expect(remaining == .milliseconds(200))
    }

    /// A scroll still in progress owes the whole delay again, which is the half of the rule that
    /// was right: flicking through a scope must not queue a write and a sync push per row.
    @Test("A scroll that has only just happened owes the whole delay")
    func recentScrollOwesTheWholeDelay() {
        #expect(PositionDebounce.remainingQuiet(sinceLastScroll: .zero, delay: delay) == delay)
        #expect(
            PositionDebounce.remainingQuiet(sinceLastScroll: .milliseconds(100), delay: delay)
                == .milliseconds(1_400)
        )
    }

    @Test("A fold that has held still for the whole delay is settled")
    func quietForTheDelayIsSettled() {
        #expect(PositionDebounce.remainingQuiet(sinceLastScroll: delay, delay: delay) == .zero)
        #expect(PositionDebounce.remainingQuiet(sinceLastScroll: .seconds(30), delay: delay) == .zero)
    }

    /// Never scrolled at all, which is the state a restore leaves behind: it settles the fold by
    /// its own scrolling and then marks itself finished. Owing a delay there would mean the first
    /// position of a session waited on a scroll that may never come.
    @Test("A fold that has never scrolled is settled")
    func neverScrolledIsSettled() {
        #expect(PositionDebounce.remainingQuiet(sinceLastScroll: nil, delay: delay) == .zero)
    }

    /// The value is fed straight back into `Task.sleep`, which treats a negative duration as no
    /// wait at all — but a negative *remainder* would also keep the loop spinning, because the
    /// loop's condition is "greater than zero". Clamped, so it exits.
    @Test("An overdue fold never reports a negative wait")
    func overdueIsNeverNegative() {
        let remaining = PositionDebounce.remainingQuiet(
            sinceLastScroll: .seconds(10),
            delay: delay
        )

        #expect(remaining == .zero)
        #expect(remaining >= .zero)
    }
}
