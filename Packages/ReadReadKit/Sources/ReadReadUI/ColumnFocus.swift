import SwiftUI

extension View {

    /// Hands keyboard focus to a column when the reader picks something in it.
    ///
    /// ## What this fixes
    ///
    /// Clicking a row selects it and nothing else: the row is marked, the reading pane fills, and
    /// SwiftUI's focus stays wherever it was — which after switching scopes is nowhere in
    /// particular. Every key the lists handle is handled through `onKeyPress`, and `onKeyPress`
    /// only fires for a focused view, so from that point on the keyboard did nothing at all. Not
    /// the arrows that move between items, not the configured letters: pressing the Open in Browser
    /// key over a row that was plainly selected opened nothing, on every list and in the reading
    /// pane alike, because the press never reached any handler.
    ///
    /// The columns already hand focus to each other with the left and right arrows, through the
    /// same `moveFocus` closure this takes — what was missing is that *clicking* in a column is
    /// equally a statement about where the reader is working.
    ///
    /// ## Why the selection and not a click
    ///
    /// The honest trigger would be the click itself, but a tap gesture over a `List` is a gesture
    /// competing with the row's own, and the risk of breaking selection to fix focus is not worth
    /// running for a case the selection already covers: a click on a row that is not already
    /// selected is what happens after every scope change, because changing scope clears the
    /// selection. What this does not cover is clicking the row that is *already* selected in a
    /// column that has lost focus — there the arrows still get focus back.
    ///
    /// Only a selection being made moves focus. Clearing one does not, and that distinction is
    /// load-bearing: `RootView` clears the selection whenever the scope changes, so treating that
    /// as a reason to focus the timeline would drag focus out of the sidebar on every click in it.
    func activatesColumn(
        _ column: FocusedColumn,
        onSelecting selection: String?,
        moveFocus: @escaping (FocusedColumn) -> Void
    ) -> some View {
        onChange(of: selection) { _, selected in
            guard selected != nil else { return }
            moveFocus(column)
        }
    }
}
