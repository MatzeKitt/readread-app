import CoreGraphics

/// Putting a row back where it was after rows landed above it.
///
/// ## Why this is arithmetic and not a `scrollTo`
///
/// A refresh prepends rows to a newest-first list, and a scroll view preserves its content
/// *offset* — so whatever was being read moves down the screen by the height of what arrived. The
/// timeline used to correct that by asking the `ScrollViewProxy` to scroll the held row back to the
/// top edge, three times over a fifth of a second. It worked, and it was visible: the rows dropped,
/// then snapped back. Every refresh twitched.
///
/// The reason it took three passes is that the first one is issued from inside the update that
/// inserted the rows, before the backing table has them, so it lands on nothing. A proxy scroll
/// cannot be made to happen sooner. Reaching the backing view directly can: the correction is one
/// subtraction, and applying it in the same geometry pass that brought the rows in means the
/// displaced frame is never drawn.
///
/// This is that subtraction, on its own so it can be tested. Both platform readers apply it — see
/// `TimelineFoldReader.Handle.holdAnchor(row:offset:)`.
enum ScrollAnchor {

    /// Slack below which a correction is not worth making.
    ///
    /// Load-bearing rather than tidiness. Both numbers come from view geometry and land on
    /// fractional pixels, so an exactly-correct anchor computes as a hair out about half the time —
    /// and a correction applied to a scroll view is itself a geometry change, which brings the hold
    /// straight back here. Without a floor the two feed each other for as long as the hold lasts.
    static let tolerance: CGFloat = 0.5

    /// How far the viewport must move for `rowTop` to sit `offset` below its top edge.
    ///
    /// - Parameters:
    ///   - rowTop: The row's top, in the scrolling content's coordinates.
    ///   - offset: Where it should sit relative to the viewport's top edge. Positive is below,
    ///     which is where the fold row always is — it is the first row *entirely* on screen.
    ///   - viewportTop: The top of the visible area, in the same coordinates as `rowTop`.
    /// - Returns: The distance to move, or `nil` when it is already close enough to leave alone.
    static func correction(rowTop: CGFloat, offset: CGFloat, viewportTop: CGFloat) -> CGFloat? {
        let delta = (rowTop - offset) - viewportTop
        guard abs(delta) > tolerance else { return nil }
        return delta
    }
}
