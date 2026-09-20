import Foundation
import Testing

@testable import ReadReadUI

/// Remembering how wide the reader dragged the two resizable columns.
///
/// The half that can be asserted here is the bookkeeping: what is stored, what is handed back at
/// the next launch, and what is left alone. Whether the split view actually opens at that width is
/// a question only a running app answers — `ColumnWidths` documents how that was measured.
///
/// Every test gets a `UserDefaults` suite of its own, because a test that writes to the real
/// defaults would resize somebody's actual window.
@MainActor
@Suite("Column widths")
struct ColumnWidthsTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "readread-tests-columns-\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The whole point: drag it, quit, and find it where you left it.
    @Test("A column opens at the width it was last left at")
    func remembersARecordedWidth() {
        let defaults = defaults("remembers")

        ColumnWidths(defaults: defaults).recordTimeline(505)

        let nextLaunch = ColumnWidths(defaults: defaults)
        #expect(nextLaunch.timeline == 505)
    }

    /// Both columns, separately — the sidebar is the one macOS used to get right on its own, and
    /// it has to keep working now that the app has taken the job over.
    @Test("Both columns are remembered, and do not borrow each other's width")
    func remembersBothColumns() {
        let defaults = defaults("both")

        let widths = ColumnWidths(defaults: defaults)
        widths.recordSidebar(310)
        widths.recordTimeline(430)

        let nextLaunch = ColumnWidths(defaults: defaults)
        #expect(nextLaunch.sidebar == 310)
        #expect(nextLaunch.timeline == 430)
    }

    @Test("A first launch opens at the designed widths")
    func fallsBackToTheDesignWidths() {
        let widths = ColumnWidths(defaults: defaults("fresh"))

        #expect(widths.sidebar == 250)
        #expect(widths.timeline == 400)
    }

    /// A width can outlive the limits that produced it — a narrower screen, or a later build that
    /// moved them. Clamping on the way in and on the way out keeps a stale number from opening a
    /// column at a size the app no longer allows.
    @Test("A width outside the allowed range is brought back inside it")
    func clampsStoredWidths() {
        let tooWide = defaults("too-wide")
        tooWide.set(2_000.0, forKey: "media.kitt.readread.columnWidth.timeline")
        #expect(ColumnWidths(defaults: tooWide).timeline == ColumnWidths.timelineLimits.upperBound)

        let tooNarrow = defaults("too-narrow")
        tooNarrow.set(10.0, forKey: "media.kitt.readread.columnWidth.sidebar")
        #expect(ColumnWidths(defaults: tooNarrow).sidebar == ColumnWidths.sidebarLimits.lowerBound)
    }

    /// The `let` contract, asserted. Were the opening width to follow the recorded one, SwiftUI
    /// would re-apply it mid-session and shove the divider back under the cursor dragging it.
    @Test("Recording a width does not move the column that is already open")
    func recordingDoesNotChangeTheOpeningWidth() {
        let widths = ColumnWidths(defaults: defaults("stable"))

        widths.recordTimeline(520)

        #expect(widths.timeline == 400)
    }

    /// A drag reports a new width for every point it travels. Writing only what changed keeps that
    /// from becoming several hundred writes to `UserDefaults` per drag.
    @Test("A width that has not changed is not written back")
    func skipsUnchangedWidths() {
        let defaults = defaults("unchanged")
        let widths = ColumnWidths(defaults: defaults)

        widths.recordTimeline(400.4)

        #expect(defaults.object(forKey: "media.kitt.readread.columnWidth.timeline") == nil)
    }

    /// The other half of the fix: AppKit's own saved frames have to go, because while one exists
    /// SwiftUI ignores the width the app asks for. Nothing else in the domain may go with them —
    /// the window's own saved frame sits one key away and is the reason the window opens where it
    /// was left.
    @Test("AppKit's memory of the dividers is discarded, and nothing else is")
    func discardsOnlyTheSplitViewAutosave() {
        let defaults = defaults("discard")
        defaults.set(["0, 0, 250, 820"], forKey: "NSSplitView Subview Frames SwiftUI.WindowGroup<X>-1-AppWindow-1")
        defaults.set("560 320 1280 820 0 0 1800 1080", forKey: "NSWindow Frame SwiftUI.WindowGroup<X>-1-AppWindow-1")
        defaults.set(310.0, forKey: "media.kitt.readread.columnWidth.sidebar")

        ColumnWidths.discardSystemAutosave(in: defaults)

        #expect(defaults.object(forKey: "NSSplitView Subview Frames SwiftUI.WindowGroup<X>-1-AppWindow-1") == nil)
        #expect(defaults.object(forKey: "NSWindow Frame SwiftUI.WindowGroup<X>-1-AppWindow-1") != nil)
        #expect(defaults.object(forKey: "media.kitt.readread.columnWidth.sidebar") as? Double == 310)
    }
}
