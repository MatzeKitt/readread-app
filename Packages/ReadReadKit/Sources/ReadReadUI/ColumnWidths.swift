import Foundation
import SwiftUI

/// How wide the reader has dragged the sidebar and the timeline, remembered between launches.
///
/// ## Why the app has to do this itself
///
/// macOS 26 remembers one of the two columns. A `NavigationSplitView` is an
/// `NSSplitViewController` underneath, and AppKit autosaves its divider positions into
/// `UserDefaults` under `NSSplitView Subview Frames …` without being asked. On relaunch the
/// sidebar comes back exactly where it was left — and the timeline does not. It opens at its
/// minimum, and that minimum is then written back over the width that was saved, so the dragged
/// width is not merely ignored but lost.
///
/// Measured rather than assumed: dragging the middle divider to give the timeline 450pt, quitting
/// and relaunching puts it back at 320pt, its `min:`, while the sidebar beside it holds the 250pt
/// it was left at. Removing `navigationSplitViewColumnWidth` from the timeline does not help — it
/// then opens at SwiftUI's own 200pt default instead. Neither does constraining the detail column.
/// The timeline is simply not restored.
///
/// ## How it is put back
///
/// `ideal:` is the only lever SwiftUI offers, and it is honoured **only when AppKit has nothing
/// stored** — with a saved frame present, `ideal:` is ignored and the column takes its minimum. So
/// the app throws AppKit's saved frames away at launch (`discardSystemAutosave`) and hands both
/// columns a remembered `ideal:` instead. Both, not just the timeline: once the autosave is gone
/// the sidebar needs remembering too, and one mechanism for two columns beats two mechanisms.
///
/// The opening widths are read once, in `init`, and are `let` for a reason. Feeding a value that
/// changes back into `ideal:` would have SwiftUI re-apply it mid-session and fight the drag that
/// produced it; recording a width therefore writes to `UserDefaults` and leaves this instance's
/// `sidebar` and `timeline` alone until the next launch.
@MainActor
public final class ColumnWidths {

    /// Narrower than this and most feed titles truncate before their count badge; wider and the
    /// sidebar is just taking room from the two columns doing the work.
    public static let sidebarLimits = 200.0...360.0

    /// Wide enough for a title plus a three-line excerpt to be worth reading, capped so the
    /// article column keeps a comfortable measure.
    public static let timelineLimits = 320.0...560.0

    private static let sidebarKey = "media.kitt.readread.columnWidth.sidebar"
    private static let timelineKey = "media.kitt.readread.columnWidth.timeline"

    /// What AppKit calls its own autosaved divider positions. One key per split view, the rest of
    /// the name being the mangled type of the SwiftUI window's content.
    private static let autosavePrefix = "NSSplitView Subview Frames "

    /// The width to open the sidebar at.
    public let sidebar: Double

    /// The width to open the timeline at.
    public let timeline: Double

    private let defaults: UserDefaults

    /// What was last written, so a drag does not put the same number to `UserDefaults` forty times.
    private var written: [String: Double] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebar = Self.stored(Self.sidebarKey, in: defaults, limits: Self.sidebarLimits, fallback: 250)
        timeline = Self.stored(Self.timelineKey, in: defaults, limits: Self.timelineLimits, fallback: 400)
        written = [Self.sidebarKey: sidebar, Self.timelineKey: timeline]
    }

    public func recordSidebar(_ width: Double) {
        record(width, forKey: Self.sidebarKey, limits: Self.sidebarLimits)
    }

    public func recordTimeline(_ width: Double) {
        record(width, forKey: Self.timelineKey, limits: Self.timelineLimits)
    }

    /// Throws away AppKit's own memory of the divider positions.
    ///
    /// Called before the window exists, because a saved frame silences `ideal:` — see the note on
    /// the type. Every split view in the app is covered by the prefix; there is one, and its key
    /// carries a mangled Swift type name that is not worth matching more precisely.
    public static func discardSystemAutosave(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(autosavePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func stored(
        _ key: String,
        in defaults: UserDefaults,
        limits: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        // `object(forKey:)` rather than `double(forKey:)`: a missing key reads as 0, which would
        // clamp to the minimum and look like a deliberately narrow column.
        guard let stored = defaults.object(forKey: key) as? Double else { return fallback }
        return min(max(stored, limits.lowerBound), limits.upperBound)
    }

    /// Recorded on the Mac only. Nowhere else is there a divider to drag, so every width an iPad
    /// would report is the system's own arithmetic answering a rotation or a multitasking change —
    /// nothing a reader chose, and nothing worth keeping.
    private func record(_ width: Double, forKey key: String, limits: ClosedRange<Double>) {
        #if os(macOS)
        let clamped = min(max(width, limits.lowerBound), limits.upperBound)
        // Sub-point differences are the layout settling, not somebody dragging.
        guard abs(clamped - (written[key] ?? 0)) >= 1 else { return }
        written[key] = clamped
        defaults.set(clamped, forKey: key)
        #endif
    }
}
