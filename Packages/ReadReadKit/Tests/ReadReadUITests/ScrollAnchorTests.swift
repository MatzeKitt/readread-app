import Testing

@testable import ReadReadUI

/// The arithmetic that keeps a refresh from moving the list under the reader.
///
/// Tested on its own because the thing it replaced *worked* and was merely visible — the rows
/// dropped and snapped back on every refresh — so a regression here does not fail loudly. It comes
/// back as a twitch, or, if the tolerance goes, as a scroll view correcting its own corrections.
@Suite("Scroll anchor")
struct ScrollAnchorTests {

    /// The case this exists for: twenty rows arrived above the fold, so the held row now sits that
    /// much further down the content and the viewport has to follow it.
    @Test("Content arriving above the fold moves the viewport by as much")
    func insertionAboveMovesTheViewport() {
        // The row was 4pt below the top edge at 1,000; the same row is now at 1,600.
        let delta = ScrollAnchor.correction(rowTop: 1_600, offset: 4, viewportTop: 996)
        #expect(delta == 600)
    }

    /// Corrections go both ways. A row height re-measured smaller pulls the held row back up, and
    /// leaving that uncorrected is the creep this replaced.
    @Test("Content shrinking above the fold moves the viewport back")
    func shrinkingAboveMovesTheViewportBack() {
        let delta = ScrollAnchor.correction(rowTop: 900, offset: 4, viewportTop: 996)
        #expect(delta == -100)
    }

    /// The floor, and it is not cosmetic. Applying a correction to a scroll view is itself a
    /// geometry change, which brings the hold straight back here — so an anchor that computes as a
    /// hair out on every pass would have the two feeding each other for as long as the hold lasts.
    @Test("An anchor already within tolerance is left alone")
    func withinToleranceIsLeftAlone() {
        #expect(ScrollAnchor.correction(rowTop: 1_000, offset: 4, viewportTop: 996) == nil)
        #expect(ScrollAnchor.correction(rowTop: 1_000.4, offset: 4, viewportTop: 996) == nil)
        #expect(ScrollAnchor.correction(rowTop: 999.6, offset: 4, viewportTop: 996) == nil)
    }

    /// Just outside it, in both directions, so the tolerance is a floor rather than a dead zone
    /// wide enough to hide a real row's worth of movement.
    @Test("An anchor just outside tolerance is corrected")
    func outsideToleranceIsCorrected() {
        #expect(ScrollAnchor.correction(rowTop: 1_001, offset: 4, viewportTop: 996) == 1)
        #expect(ScrollAnchor.correction(rowTop: 999, offset: 4, viewportTop: 996) == -1)
    }

    /// The offset is what the hold restores, and restoring the *edge* instead is what used to make
    /// the reading position creep a row per refresh: the fold row sits a little below the top edge
    /// by definition — it is the first row entirely on screen — so pinning it flush reads as one
    /// row further down, and the next commit writes that down as a move nobody made.
    @Test("The offset is part of the target, not slack around it")
    func offsetIsPartOfTheTarget() {
        // Same row, same viewport: the only difference is where the row is meant to sit.
        #expect(ScrollAnchor.correction(rowTop: 1_000, offset: 0, viewportTop: 996) == 4)
        #expect(ScrollAnchor.correction(rowTop: 1_000, offset: 30, viewportTop: 996) == -26)
    }
}
