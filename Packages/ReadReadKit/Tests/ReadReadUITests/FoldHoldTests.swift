import Testing

@testable import ReadReadUI

/// The rule that keeps an auto-refresh from marking everything it just fetched as read.
///
/// Worth testing in isolation because the failure it guards against is silent and unrecoverable.
/// When items are prepended, the row against the top edge is the newest arrival — not where the
/// reader is — and committing that as the reading position destroys the only record of where they
/// were. This app has no read/unread state to fall back on.
@Suite("Fold hold")
struct FoldHoldTests {

    /// The case that was the bug. The pin missed, the list is still at the top, and the screen says
    /// row 0 while the reader is really twenty rows down.
    @Test("A list still sitting above the held row stays held")
    func aboveTheHeldRowStaysHeld() {
        #expect(FoldHold.isReleased(liveRow: 0, heldRow: 20) == false)
        #expect(FoldHold.isReleased(liveRow: 19, heldRow: 20) == false)
    }

    /// The pin landing, which is the ordinary case. `scrollTo(anchor: .top)` lands within a
    /// fraction of a point, so the reader may report the held row or the one below it.
    @Test("The pin landing releases the hold")
    func landingReleases() {
        #expect(FoldHold.isReleased(liveRow: 20, heldRow: 20))
        #expect(FoldHold.isReleased(liveRow: 21, heldRow: 20))
    }

    /// The reader carrying on reading. Unambiguous — an insertion cannot move the fold *down* the
    /// list — so this is the one signal that says tracking may resume.
    @Test("Reading on past the held row releases the hold")
    func readingOnReleases() {
        #expect(FoldHold.isReleased(liveRow: 45, heldRow: 20))
    }

    /// Pruning, a filter change, or an account being switched off. There is no held row to compare
    /// against any more, so continuing to suppress the screen would freeze the count for good.
    @Test("A held item that has left the list releases the hold")
    func vanishedItemReleases() {
        #expect(FoldHold.isReleased(liveRow: 3, heldRow: nil))
        #expect(FoldHold.isReleased(liveRow: nil, heldRow: nil))
    }

    /// A table that cannot say where the fold is must not be taken as saying "row 0".
    @Test("An unreadable screen holds")
    func unknownLiveRowHolds() {
        #expect(FoldHold.isReleased(liveRow: nil, heldRow: 20) == false)
    }

    /// The top of the list, held at the top of the list: caught up, nothing arrived above it.
    @Test("The top row held at the top is released")
    func topRowIsReleased() {
        #expect(FoldHold.isReleased(liveRow: 0, heldRow: 0))
    }

    // MARK: - The evidence geometry cannot give

    /// The case that froze an iPhone's counts and its reading position.
    ///
    /// Coming back to the app after a while puts the new items at the top, so the reader scrolls
    /// *up* into them — and a fold above the held row is exactly what the geometry rule refuses to
    /// believe. Without the scroller to ask, the hold never lifted: the counts stopped moving, and
    /// opening an item wrote the position the app had been restored to.
    @Test("A reader scrolling up out of the held row releases the hold")
    func scrollingReaderReleases() {
        #expect(FoldHold.isReleased(liveRow: 4, heldRow: 20) == false)
        #expect(FoldHold.isReleased(
            liveRow: 4,
            heldRow: 20,
            readerIsScrolling: true,
            heldFor: .milliseconds(50),
            limit: .seconds(1)
        ))
    }

    /// The backstop. Keyboard scrolling touches no scroller, so the gesture above never reports —
    /// and a hold that outlives its insertion by a second has plainly not been lifted by evidence.
    @Test("A hold that outlives its limit releases whatever the geometry says")
    func staleHoldReleases() {
        #expect(FoldHold.isReleased(
            liveRow: 4,
            heldRow: 20,
            readerIsScrolling: false,
            heldFor: .milliseconds(400),
            limit: .seconds(1)
        ) == false)
        #expect(FoldHold.isReleased(
            liveRow: 4,
            heldRow: 20,
            readerIsScrolling: false,
            heldFor: .seconds(1),
            limit: .seconds(1)
        ))
    }

    /// An unreadable screen still holds while the insertion is settling, because the alternative is
    /// treating "I cannot say" as "row 0" — which is how a refresh once marked everything it had
    /// just fetched as read.
    @Test("An unreadable screen still holds inside the limit")
    func unknownLiveRowStillHolds() {
        #expect(FoldHold.isReleased(
            liveRow: nil,
            heldRow: 20,
            readerIsScrolling: false,
            heldFor: nil,
            limit: .seconds(1)
        ) == false)
    }
}
