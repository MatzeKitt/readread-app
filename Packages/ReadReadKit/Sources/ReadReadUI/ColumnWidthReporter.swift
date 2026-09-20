import SwiftUI

#if os(macOS)
import AppKit
#endif

/// A view of no size whose only job is to notice how wide the columns are.
///
/// ## Why not `onGeometryChange`
///
/// Because it answers the wrong number for the column that matters. Measured during launch, the
/// timeline column reports its width three times — 500, then 0, then 200 — and stops at 200 while
/// the column on screen is 500 wide. The last value is the one a recorder keeps, so a perfectly
/// good remembered width gets overwritten with a transient one. The sidebar reports itself
/// correctly, but a rule that works for one column and quietly corrupts the other is worse than
/// no rule.
///
/// The split view underneath has no such ambiguity: its subview frames *are* the column layout,
/// and AppKit posts a notification once they settle — including after every divider drag, which
/// is the event this whole thing exists to catch.
///
/// ## What it reads
///
/// Not the subview widths, which overlap: under Liquid Glass the sidebar floats over the timeline
/// and the timeline's own view runs back to the window's leading edge, so its `frame.width`
/// includes the sidebar. The column boundaries are the trailing edges, so each column is the gap
/// between its own `maxX` and the previous one's.
///
/// If the hierarchy is ever not what this expects, nothing is recorded and the columns keep
/// whatever width they were last given — the failure is a forgetful app, not a broken one.
struct ColumnWidthReporter: View {

    let widths: ColumnWidths

    var body: some View {
        #if os(macOS)
        SplitViewObserver(widths: widths)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
private struct SplitViewObserver: NSViewRepresentable {

    let widths: ColumnWidths

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.widths = widths
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ObservingView)?.widths = widths
    }

    private final class ObservingView: NSView {

        var widths: ColumnWidths?

        private var observation: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            // Re-found on every move rather than cached: a view can be pulled out of one window
            // and put into another, and an observation of the old split view would then be
            // reporting somebody else's columns. This is also where the observation is dropped —
            // removal from a window arrives here with a `nil` window, and both the view and the
            // split view are held weakly, so a hierarchy torn down without that courtesy leaves
            // nothing behind but a block that does nothing.
            if let observation {
                NotificationCenter.default.removeObserver(observation)
                self.observation = nil
            }
            guard window != nil, let split = enclosingSplitView() else { return }

            observation = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: split,
                queue: .main
            ) { [weak self, weak split] _ in
                // The notification is delivered on the main queue, which on AppKit's side is the
                // main thread; the closure is `@Sendable` only because `addObserver` says so.
                MainActor.assumeIsolated {
                    guard let self, let split else { return }
                    self.report(split)
                }
            }
            report(split)
        }

        private func enclosingSplitView() -> NSSplitView? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView { return split }
                view = current.superview
            }
            return nil
        }

        private func report(_ split: NSSplitView) {
            let columns = split.arrangedSubviews
            guard columns.count == 3, let widths else { return }

            let sidebarEdge = columns[0].frame.maxX
            let timelineEdge = columns[1].frame.maxX

            // A collapsed sidebar is hidden, not narrow. Recording the zero it reports would
            // clamp to the minimum and lose the width it had before it was put away.
            if !columns[0].isHidden, sidebarEdge > 0 {
                widths.recordSidebar(sidebarEdge)
            }
            let timeline = timelineEdge - (columns[0].isHidden ? 0 : sidebarEdge)
            if !columns[1].isHidden, timeline > 0 {
                widths.recordTimeline(timeline)
            }
        }
    }
}
#endif
