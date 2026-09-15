import SwiftUI

extension View {

    /// Names a toolbar button on hover, leaving the icon to speak for itself the rest of the time.
    ///
    /// A toolbar `Button("Read Later", systemImage: "bookmark")` renders icon-only, so the window's
    /// top strip is a row of unlabelled glyphs: a bookmark, a compass, a share box, a refresh
    /// arrow. Each is guessable in isolation and none of them says what it acts *on* — and on a
    /// merged macOS toolbar they sit in one strip with the timeline's own buttons, so "which pane
    /// does this belong to" was a matter of memory.
    ///
    /// Drawing the titles permanently answered that and cost more than it was worth: five titled
    /// buttons is most of a window's width, and a toolbar of words reads as a menu bar. A tooltip
    /// is the platform's own answer — the name is there for whoever needs it, on the gesture people
    /// already make when they do not recognise an icon, and absent for everyone else.
    ///
    /// The title is passed rather than taken from the button, because a modifier cannot see the
    /// label of the view it is applied to. That means the same string twice at each call site; it
    /// is the same *key* both times, so it is one entry in the catalogue and one translation.
    ///
    /// - Parameter title: The button's own title, verbatim.
    func toolbarButtonHelp(_ title: LocalizedStringKey) -> some View {
        // `.help` is the tooltip on the Mac and an accessibility hint on iOS, where there is no
        // hover — harmless there, and the buttons carry their titles as accessibility labels
        // already by virtue of being `Button(title, systemImage:)`.
        help(title)
    }
}
