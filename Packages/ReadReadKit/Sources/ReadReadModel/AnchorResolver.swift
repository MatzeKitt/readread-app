import Foundation

/// Which row of a new snapshot takes over from the row the reader was looking at in the old one.
///
/// The anchor is the fold item. Applying a snapshot keeps that item at the same distance from the
/// top of the viewport, so what was on screen is still on screen, pixel for pixel. That only needs
/// deciding when the item is no longer in the new snapshot — pruned by retention, hidden by a
/// filter, its account switched off.
///
/// ## Why the replacement is looked for downwards first
///
/// Everything above the fold is still to be read. Replacing a vanished anchor with a *newer* item
/// would put the fold above rows the reader has not seen, and the next settle would record them as
/// passed. An older neighbour leaves at most a row already read above the fold, which costs one
/// item of count and loses nothing.
public enum AnchorResolver {

    public struct Resolution: Equatable, Sendable {

        /// The row in the new snapshot to put where the anchor was.
        public var row: Int

        /// Whether that row is the anchor itself. When it is not, the offset the anchor sat at no
        /// longer describes anything, and the replacement goes flush against the fold.
        public var isSameItem: Bool

        public init(row: Int, isSameItem: Bool) {
            self.row = row
            self.isSameItem = isSameItem
        }
    }

    /// - Parameters:
    ///   - anchor: The row at the fold in the old snapshot.
    ///   - old: The snapshot that was on screen.
    ///   - new: The snapshot about to replace it.
    /// - Returns: `nil` only when the new snapshot is empty.
    public static func resolve(
        anchor: TimelineRow,
        old: TimelineSnapshot,
        new: TimelineSnapshot
    ) -> Resolution? {
        guard !new.isEmpty else { return nil }

        if let row = new.row(of: anchor.id) {
            return Resolution(row: row, isSameItem: true)
        }

        if let oldRow = old.row(of: anchor.id) {
            // Older neighbours first: they sit below the anchor in a newest-first list.
            for candidate in old.rows[(oldRow + 1)...] {
                if let row = new.row(of: candidate.id) {
                    return Resolution(row: row, isSameItem: false)
                }
            }
            for candidate in old.rows[..<oldRow].reversed() {
                if let row = new.row(of: candidate.id) {
                    return Resolution(row: row, isSameItem: false)
                }
            }
        }

        // Nothing the reader could see survived. The anchor's own key still says where in time they
        // were, and that does not depend on any row surviving — never the top of the list, which
        // would record everything above as read.
        guard let row = new.foldRow(for: anchor.sortKey) else { return nil }
        return Resolution(row: row, isSameItem: false)
    }
}
