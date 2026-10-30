import Testing

@testable import ReadReadUI

/// The line between timeline items: between items only, and never against the selection.
@Suite("RowSeparator")
struct RowSeparatorTests {

    @Test("A line between every pair of items, none under the last")
    func betweenItems() {
        #expect(RowSeparator.isShown(below: 0, count: 3, selectedRow: nil))
        #expect(RowSeparator.isShown(below: 1, count: 3, selectedRow: nil))
        #expect(!RowSeparator.isShown(below: 2, count: 3, selectedRow: nil))
        #expect(!RowSeparator.isShown(below: 0, count: 1, selectedRow: nil))
    }

    @Test("No line above or below the selected item")
    func notAgainstSelection() {
        #expect(RowSeparator.isShown(below: 0, count: 5, selectedRow: 2))
        #expect(!RowSeparator.isShown(below: 1, count: 5, selectedRow: 2))
        #expect(!RowSeparator.isShown(below: 2, count: 5, selectedRow: 2))
        #expect(RowSeparator.isShown(below: 3, count: 5, selectedRow: 2))
    }

    @Test("Moving the selection redraws the rows on both sides of the old and the new one")
    func affectedRows() {
        #expect(RowSeparator.rowsAffected(bySelectionChangeFrom: 2, to: 5) == [1, 2, 4, 5])
        #expect(RowSeparator.rowsAffected(bySelectionChangeFrom: nil, to: 0) == [0])
        #expect(RowSeparator.rowsAffected(bySelectionChangeFrom: 3, to: nil) == [2, 3])
    }
}
