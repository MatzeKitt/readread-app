import SwiftUI

/// The one faint grey the app fills a *current* thing with.
///
/// There are two of those and they are a column apart: the selected row in the timeline, and the
/// focused post in the reading pane. They were written separately and drifted — the row took
/// `NSColor.unemphasizedSelectedContentBackgroundColor`, which is the platform's answer for a
/// selection in an unfocused list and is a decidedly solid grey, while the pane took a
/// half-strength `.quaternary`, which is barely a tint. Side by side the row shouted and the card
/// murmured, and nothing in either file said they were meant to be the same thing.
///
/// So they are one constant now, and the pane's is the one that won. A `List` selection is not
/// really *content* in this app: the timeline is a reading surface, the reader's eye is on the
/// text, and the marker only has to say where you are. The accent outline in ``SelectionMarker``
/// does that unambiguously on its own, which is what leaves the fill free to be quiet.
///
/// Note what the change is, because "darker" only describes half of it. `.quaternary` is a
/// *foreground* style at low opacity, so it always moves a shade away from whatever is behind it:
/// against a dark appearance that reads as a darker grey than the platform selection it replaces,
/// and against a light one it reads as a lighter one. Fainter in both, which is the actual
/// intent — the appearance decides which direction faint points in.
enum SurfaceFill {

    /// Boxed as `AnyShapeStyle` because both call sites choose between this and `Color.clear`, and
    /// a ternary needs the two branches to be one type.
    static let current = AnyShapeStyle(.quaternary.opacity(0.5))

    static let clear = AnyShapeStyle(Color.clear)
}
