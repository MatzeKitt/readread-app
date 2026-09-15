import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a selected row is marked in the item lists.
///
/// ## Why the platform's own selection is not used
///
/// A `List(selection:)` fills the selected row with the accent colour, which is right for a picker
/// and too loud for this: the row carries a headline, a byline and three lines of excerpt, and
/// filling the whole thing in saturated blue turns the text into knockout white and shouts the
/// selection at a reader who is looking at the *content*. In a three-column reader the selection is
/// a marker of where you are, not the thing you came to look at.
///
/// So the fill becomes the quieter grey the platform already uses for a selection in a list that
/// does not have focus, and the accent colour is spent on an outline instead — present, unmistakable
/// at a glance, and it leaves the text set in the colours it was designed in.
struct SelectionMarker: View {

    let isSelected: Bool

    /// Matching the inset a `List` gives its rows, so the outline sits around the row rather than
    /// against the edges of the column.
    private static let cornerRadius: CGFloat = 8

    private static let borderWidth: CGFloat = 1.5

    /// The fill, shared with the focused post in the reading pane. See ``SurfaceFill``.
    ///
    /// It was the platform's *unemphasised* selection colour — `unemphasizedSelectedContentBackgroundColor`
    /// on the Mac, `.tertiarySystemFill` on iOS — chosen because a platform colour is already
    /// correct in both appearances and at every accessibility contrast setting. A hierarchical
    /// style is too, and it is the quieter of the two: the platform's is sized for a list where the
    /// selection *is* the content, and here the content is what you came to read.
    private static var fill: AnyShapeStyle { SurfaceFill.current }

    var body: some View {
        // Drawn even when unselected, as a clear rectangle, rather than switching to `EmptyView`.
        // `listRowBackground` takes whatever it is handed as the row's whole background, and
        // handing it two different view types would rebuild the row's background on every
        // selection change instead of animating one shape's colours.
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(isSelected ? Self.fill : SurfaceFill.clear)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: Self.borderWidth)
            }
            // Inset vertically so consecutive selected-then-unselected rows do not share an edge,
            // and horizontally by nothing: the row's own insets already hold it off the column.
            .padding(.vertical, 1)
    }
}

extension View {

    /// Suppresses the backing list's own selection fill, so ``SelectionMarker`` is the only marking.
    ///
    /// `listRowBackground` alone is not enough on macOS: the table draws its selection over the
    /// row's background, so the accent fill would sit on top of the marker and nothing would have
    /// changed. `NSTableView.selectionHighlightStyle` is what actually turns it off, and reaching
    /// the table is what this does.
    ///
    /// A no-op on iOS, where the default selection is already an unemphasised fill — the marker's
    /// outline is then the whole of the change, drawn over a fill of the same intent.
    func plainListSelection() -> some View {
        background { PlainListSelection() }
    }
}

#if os(macOS)
/// Finds the list it is planted behind and stops it drawing its own selection.
///
/// Planted **once**, in the list's background, and never per row: attaching an
/// `NSViewRepresentable` to every row's background is fatal on macOS 26 — the window is created and
/// correctly titled but never displays — which `TimelineFoldReader` documents in full.
///
/// Re-applied from `layout()` rather than set once. SwiftUI owns this table and rebuilds its
/// configuration as the list changes; the setter is idempotent, so asking again costs a comparison
/// and covers the case where it has been reset underneath us.
private struct PlainListSelection: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        ProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {

        /// Held weakly, and held at all so the search below runs once rather than per layout pass.
        ///
        /// The search walks the whole window's view tree, and `layout()` is called while the list
        /// scrolls. Doing it there unconditionally is a recursive walk of every view in the app a
        /// few dozen times a second — the fold reader caches for exactly the same reason.
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// Re-applied rather than set once: SwiftUI owns this table and rebuilds its configuration
        /// as the list changes. The setter is idempotent, so asking again costs a comparison.
        private func apply() {
            if table == nil { table = findTable() }
            guard let table, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }

        /// The table this probe is behind.
        ///
        /// `enclosingScrollView` first, which is exact when the background sits inside the list's
        /// own scroll view. Otherwise the window is searched and disambiguated by overlap, because
        /// the sidebar is a table too and taking the first one found would restyle the wrong
        /// column — the same search, and the same reason for it, as `TimelineFoldReader`.
        private func findTable() -> NSTableView? {
            if let direct = enclosingScrollView?.documentView as? NSTableView { return direct }

            guard let root = window?.contentView else { return nil }
            let mine = convert(bounds, to: nil)
            guard !mine.isEmpty else { return nil }

            var best: (table: NSTableView, overlap: CGFloat)?
            for scrollView in Self.scrollViews(in: root) {
                guard let table = scrollView.documentView as? NSTableView else { continue }
                let area = scrollView.convert(scrollView.bounds, to: nil).intersection(mine)
                let overlap = area.width * area.height
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (table, overlap)
            }
            return best?.table
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            for subview in view.subviews {
                found.append(contentsOf: scrollViews(in: subview))
            }
            return found
        }
    }
}
#else
/// Nothing to suppress on iOS: the default row selection is already an unemphasised fill, and
/// `listRowBackground` draws over it.
private struct PlainListSelection: View {
    var body: some View { Color.clear }
}
#endif
