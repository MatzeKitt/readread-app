import Testing

@testable import ReadReadUI

/// The arithmetic between "what the backing view says is on screen" and "what the list is holding".
///
/// Worth testing in isolation because both of its failure modes are quiet. A range that reaches
/// past the array traps; a range that is merely *wrong* takes the older-item mark off articles the
/// reader has never seen, and there is nothing left afterwards to say that it did. The two sides
/// genuinely disagree in normal use: the table is handed its rows a beat after the array is
/// replaced, so an arrival or a prune leaves them out of step for a moment.
@Suite("Visible rows")
struct VisibleRowsTests {

    @Test("A range inside the list is taken as it is")
    func insideTheList() {
        #expect(VisibleRows.clamped(3...9, count: 40) == 3...9)
        #expect(VisibleRows.clamped(0...0, count: 1) == 0...0)
    }

    /// The mid-insertion case: the table still reports the rows it had, and the array it is being
    /// applied to has fewer of them.
    @Test("A range running past the end stops at the last item")
    func pastTheEnd() {
        #expect(VisibleRows.clamped(8...30, count: 12) == 8...11)
    }

    /// The other direction, after a prune: nothing the range names is there any more.
    @Test("A range entirely past the end names nothing")
    func entirelyPastTheEnd() {
        #expect(VisibleRows.clamped(40...50, count: 12) == nil)
    }

    @Test("An empty list has nothing on screen")
    func emptyList() {
        #expect(VisibleRows.clamped(0...5, count: 0) == nil)
    }

    /// The reader has not reported anything yet — the probe has not found its table, or the list
    /// has not been laid out. Nothing on screen is the right answer, rather than row zero.
    @Test("No reading names nothing")
    func noReading() {
        #expect(VisibleRows.clamped(nil, count: 40) == nil)
    }

    /// A negative lower bound is what an AppKit table answers for a point above its first row, and
    /// it must not become a negative index.
    @Test("A range starting before the first row starts at it")
    func beforeTheFirstRow() {
        #expect(VisibleRows.clamped(-2...4, count: 40) == 0...4)
    }
}
