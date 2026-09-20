#if os(macOS)
import AppKit
import SwiftUI

/// Reports which row sits at the top of a `List`'s viewport.
///
/// ## Why this needs AppKit
///
/// The reading position is "the item at the fold", and the count beside it is how many items sit
/// above the fold. That requires the fold *live*, in both directions, and a SwiftUI `List` on macOS
/// will not give it up. Measured against the running app:
///
/// - `.scrollPosition($position)` does not drive a `List` at all.
/// - `onScrollTargetVisibilityChange` never fires.
/// - `onScrollPhaseChange` never leaves `.idle`, even for keyboard scrolling.
/// - Per-row `onScrollVisibilityChange` reports rows appearing but effectively never leaving —
///   57 appearances to 1 departure over one ordinary scroll.
/// - Per-row `onGeometryChange` fires only when a row is first realised, so its frames are stale
///   snapshots taken at whatever offset happened to be current then.
///
/// The one thing that does work is `onScrollGeometryChange`, which reports the offset accurately.
/// So this type supplies the other half: a handle on the backing `NSTableView`, which can answer
/// "which row is at this point" exactly, with no accumulated geometry to go stale.
///
/// Deliberately macOS-only. On iOS a `List` is collection-view backed and the SwiftUI scroll APIs
/// behave, so that platform gets the pure-SwiftUI path in its own pass.
struct TimelineFoldReader: NSViewRepresentable {

    /// Holds the table weakly, so nothing here keeps a dead view alive.
    ///
    /// `@MainActor` because everything it touches is AppKit view state.
    @MainActor
    final class Handle {

        /// Observed on being set, so ``observeTable()`` is in place before the first hold — see
        /// there for why registering at arming time is too late.
        weak var table: NSTableView? {
            didSet { observeTable() }
        }

        /// Asks the probe to look for the table again.
        ///
        /// The probe cannot always resolve it at the moment it is planted, and rather than have it
        /// guess at a good moment, the handle can ask on demand — see `ProbeView.layout()` for what
        /// goes wrong when the search runs too early.
        var resolve: (() -> Void)?

        /// One reading of the fold: which row it is, and where it sits.
        ///
        /// Both from a single look at the geometry, deliberately. They used to be two calls, and
        /// two calls can disagree — a scroll between them attributes one row's offset to another,
        /// and the anchor hold would then pin the list a row out.
        ///
        /// - The **row** is the first one *entirely* below the top edge of the viewport. Entirely,
        ///   not merely intersecting, and the difference is the whole meaning of the number beside
        ///   the list. The count is how many items sit above the fold, so the fold row is the first
        ///   item the reader has actually been shown — and a row cut off by the top edge has not
        ///   been shown, it has been glimpsed. Counting it made the list claim "Up to date" while
        ///   one pixel of the newest item was peeking out from under the toolbar.
        /// - The **offset** is how far below that edge its top sits, which is what
        ///   ``holdAnchor(row:offset:for:)`` puts it back to. Pinning to the edge itself instead is
        ///   what used to make the position creep a row per refresh.
        ///
        /// Reads the live bounds rather than taking an offset from the caller: SwiftUI's
        /// `contentOffset` is measured through the scroll-edge insets and goes negative at the top,
        /// whereas the table's own coordinate system is what `row(at:)` expects.
        var foldReading: (row: Int, offset: CGFloat)? {
            if table == nil { resolve?() }
            guard let table, let top = viewportTop, let row = row(at: top) else { return nil }

            // A row whose own top is above the viewport's is clipped, so the first *whole* row is
            // the next one down. Clamped to the last row, because at the bottom of a list there is
            // no next row and the fold has to stay a usable index — `readFold` reads `items[row]`.
            let fold = table.rect(ofRow: row).minY < top - Self.edgeTolerance
                ? min(row + 1, table.numberOfRows - 1)
                : row
            return (fold, table.rect(ofRow: fold).minY - top)
        }

        /// The top of the visible area, in the table's own coordinates.
        ///
        /// Read from the live bounds rather than taken from a caller: SwiftUI's `contentOffset` is
        /// measured through the scroll-edge insets and goes negative at the top, whereas the
        /// table's coordinate system is what ``row(at:)`` expects.
        private var viewportTop: CGFloat? {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return nil }
            return table.convert(CGPoint(x: 0, y: clip.bounds.minY), from: clip).y
        }

        /// The row containing `y`, or nil when the table has none.
        ///
        /// Clamped into the rows before asking, because `row(at:)` answers -1 for any point outside
        /// them and both ends of a scroll produce one: the scroll-edge inset puts the top of the
        /// viewport *above* the first row — so scrolling fully to the top, the one place the count
        /// must read zero, returned no row at all — and rubber-banding past the end puts it below
        /// the last.
        ///
        /// Clamped to the rows' own rects rather than to `table.bounds`, which is wider than them:
        /// the first row starts some way below the table's origin, so clamping to the origin still
        /// landed outside and still answered -1.
        private func row(at y: CGFloat) -> Int? {
            guard let table, table.numberOfRows > 0 else { return nil }
            let first = table.rect(ofRow: 0)
            let last = table.rect(ofRow: table.numberOfRows - 1)
            let clamped = min(max(y, first.minY), max(first.minY, last.maxY - 1))
            let row = table.row(at: CGPoint(x: 0, y: clamped))
            return row >= 0 ? row : nil
        }

        /// The fold row alone, for the callers that do not care where it sits.
        var foldRow: Int? { foldReading?.row }

        /// Slack when deciding whether a row's top is above the viewport's.
        ///
        /// Both numbers come from view geometry and land on fractional pixels, so an exactly
        /// aligned row compares as a hair above the edge about half the time. Without this the
        /// count flickers between 0 and 1 while the list sits perfectly still at the top.
        private static let edgeTolerance: CGFloat = 0.5

        // MARK: - Holding the anchor

        /// A row being kept where it is while rows land above it.
        private struct Hold {
            var row: Int
            var offset: CGFloat
            var expiresAt: Date
        }

        private var hold: Hold?

        /// Owns the frame-change registration, so it can be torn down from a nonisolated `deinit`.
        private let geometry = NotificationRegistration()

        /// Owns the live-scroll registration.
        ///
        /// Separate from ``geometry`` rather than sharing it, because each is registered at its own
        /// moment and `isRegistered` is the test for whether it has been — one registration object
        /// holding both would report the other's as its own.
        private let scrolling = NotificationRegistration()

        /// When the reader last had hold of the scroller.
        private var lastLiveScrollAt: Date?

        /// How long after the last scroll event the reader still counts as scrolling.
        ///
        /// Only used to decide whether a hold gets *one* correction or goes on correcting for its
        /// whole window — see ``pinIfHolding()``. Short, because it only has to bridge the gap
        /// between two scroll events of the same gesture.
        private static let liveScrollQuiet: TimeInterval = 0.1

        /// Whether a deferred correction is already on its way.
        private var correctionScheduled = false

        /// A row and where its top sits in the **content**, as the reference for a resize.
        ///
        /// Content coordinates, not screen ones, and that is the whole of why this works: a row's
        /// top only moves when the layout above it changes. The reader scrolling does not move it,
        /// so a snapshot taken a moment ago is still exact however much they have scrolled since —
        /// which is what lets a correction be computed during a gesture without fighting it.
        private var anchorSnapshot: (row: Int, rowTop: CGFloat)?

        /// Growth above the anchor that has not been compensated for yet.
        ///
        /// Accumulated rather than applied on the spot, because a resize arrives during layout and
        /// the correction has to wait for the next run-loop turn — and several resizes can land
        /// before it gets there.
        private var pendingResizeDelta: CGFloat = 0

        /// The row the top edge of the viewport cuts through, and where its top sits.
        ///
        /// ## Why this row and not the fold
        ///
        /// The anchor used to be the fold — the first row *entirely* below the top edge — because
        /// the list was already computing that and it seemed like the same question. It is not, and
        /// the difference is a whole row of error in the one direction that shows.
        ///
        /// The fold sits one row *below* the top edge, so the row straddling that edge counts as
        /// being "above the anchor". When that row is the one being realised — and it always is,
        /// because a row is realised as it comes into view — its growth was treated as growth
        /// off-screen and compensated for. But a straddling row grows *downwards* from a top that
        /// has not moved: nothing above it moves, nothing the reader is looking at needs correcting,
        /// and scrolling anyway is a pure displacement. Measured in the log as `+111` per resize,
        /// over and over, one for every row that came into view.
        ///
        /// Anchoring on the straddling row's own top draws the line in the right place: growth
        /// above it is genuinely invisible and worth compensating, growth inside or below it is on
        /// screen and must be left alone.
        private func topRowSnapshot() -> (row: Int, rowTop: CGFloat)? {
            guard let table, let top = viewportTop, let row = row(at: top) else { return nil }
            return (row, table.rect(ofRow: row).minY)
        }

        /// Measures how far the anchor moved within the content, at the moment it moved.
        ///
        /// Read-only, so it is safe to run inside the layout pass that caused the resize — and it
        /// has to run there, because the *previous* position of the row is only knowable before
        /// something else re-samples it.
        private func noteContentResize() {
            // Nothing to measure against yet — the list has not moved since it appeared.
            // Taking the snapshot now means the *next* resize is corrected rather than this
            // one, which is the honest answer: the previous position genuinely is not known.
            guard anchorSnapshot != nil else {
                anchorSnapshot = topRowSnapshot()
                return
            }
            guard hold == nil, let snapshot = anchorSnapshot, let table else { return }
            guard snapshot.row >= 0, snapshot.row < table.numberOfRows else {
                anchorSnapshot = nil
                return
            }

            let rowTop = table.rect(ofRow: snapshot.row).minY
            anchorSnapshot = (snapshot.row, rowTop)

            let growth = rowTop - snapshot.rowTop
            guard abs(growth) > ScrollAnchor.tolerance else { return }
            pendingResizeDelta += growth
            ScrollDiagnostics.shared.note(String(
                format: "anchor row=%d moved %+.1f within the content",
                snapshot.row,
                growth
            ))
        }

        /// Keeps `row` at `offset` below the top edge for a short while.
        ///
        /// Armed as items arrive and applied from the table's *own* layout, which is what makes
        /// the correction invisible: the rows and the compensating offset land in one pass instead
        /// of the rows landing low and being scrolled back a frame later. See ``ScrollAnchor``.
        ///
        /// - Parameters:
        ///   - row: Where the held item sits in the **new** list. The caller knows this before the
        ///     table does, which is the point — it is looking at the array the table is about to
        ///     be handed.
        ///   - duration: How long to keep correcting. Short: a reader who starts scrolling the
        ///     instant items land must not be fighting a pin that outlives the insertion.
        func holdAnchor(row: Int, offset: CGFloat, for duration: TimeInterval) {
            hold = Hold(row: row, offset: offset, expiresAt: Date(timeIntervalSinceNow: duration))
            observeTable()
            scheduleCorrection()
        }

        func releaseAnchor() {
            hold = nil
        }

        /// Applies the correction, if one is being held and the table can be asked yet.
        ///
        /// - Returns: Whether the hold could be applied. `false` while the table still has the old
        ///   rows, which is the ordinary case at the moment the hold is armed — the caller retries.
        @discardableResult
        func pinIfHolding() -> Bool {
            guard let hold else { return false }
            guard Date() < hold.expiresAt else {
                releaseAnchor()
                return false
            }
            guard let table, let scrollView = table.enclosingScrollView else { return false }
            // The table has not been handed the new rows yet. Nothing to do but wait to be asked
            // again — from its own frame change, a moment from now.
            guard hold.row >= 0, hold.row < table.numberOfRows else {
                ScrollDiagnostics.shared.note("pin deferred — row \(hold.row) of \(table.numberOfRows)")
                return false
            }

            let clip = scrollView.contentView
            let viewportTop = table.convert(CGPoint(x: 0, y: clip.bounds.minY), from: clip).y
            let rowTop = table.rect(ofRow: hold.row).minY
            ScrollDiagnostics.shared.note(String(
                format: "pin inputs row=%d rowTop=%.1f offset=%.1f viewportTop=%.1f rows=%d",
                hold.row,
                rowTop,
                hold.offset,
                viewportTop,
                table.numberOfRows
            ))
            guard let delta = ScrollAnchor.correction(
                rowTop: rowTop,
                offset: hold.offset,
                viewportTop: viewportTop
            ) else {
                // Already where it should be, which is a successful hold rather than a failed one.
                if isLiveScrolling { releaseAnchor() }
                return true
            }

            // `setBoundsOrigin` plus `reflectScrolledClipView` rather than `scroll(to:)`: this is
            // the documented way to move a clip view without animating, and an animation here
            // would be the very movement being removed. Applied as a delta, because converting an
            // absolute point back through the clip view reads the bounds origin this is setting.
            ScrollDiagnostics.shared.attribute(String(format: "pin row=%d delta=%+.1f", hold.row, delta))
            clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
            // Attributed separately from the line above, because it is a second chance to move the
            // list: `reflectScrolledClipView` re-validates the clip against the document view, and
            // a document view that has not been resized yet would be re-validated *against the old
            // content*. Sharing one attribution with `setBoundsOrigin` reported any such movement
            // as nobody's doing.
            ScrollDiagnostics.shared.attribute("pin (reflect)")
            scrollView.reflectScrolledClipView(clip)
            ScrollDiagnostics.shared.clearAttribution()

            // A reader who is moving gets one correction and no more.
            //
            // Both halves of that matter, and the first version of this guard got the first half
            // wrong: it declined to correct at all while the list was being scrolled, on the theory
            // that a pin fights the gesture. A pin against a *stale* anchor fights the gesture —
            // that was the real fault, and it is fixed where the anchor is recorded. What an
            // arrival does to the content is worth undoing whether or not a finger is down; going
            // on undoing it for the rest of the hold window, against someone who is deliberately
            // moving, is the fight.
            if isLiveScrolling { releaseAnchor() }
            return true
        }

        /// Whether the reader has hold of the list.
        ///
        /// Exposed so the list can tell a fold that moved because items arrived from one that moved
        /// because the reader moved it — see ``FoldHold``.
        var isReaderScrolling: Bool { isLiveScrolling }

        /// Whether the reader is scrolling, or has just been.
        ///
        /// Assembled from notifications because an `NSScrollView` will not say on demand — the iOS
        /// reader gets to ask `isDragging` directly.
        private var isLiveScrolling: Bool {
            guard let lastLiveScrollAt else { return false }
            return Date().timeIntervalSince(lastLiveScrollAt) < Self.liveScrollQuiet
        }

        /// Scrolls by however far the content above the anchor grew, so the anchor stays put.
        ///
        /// ## The case no hold covers
        ///
        /// A hold is armed when items *arrive*, because that is when the list knows a row's index
        /// is about to change. But the content above the viewport changes height constantly with
        /// the item set untouched: a `List` gives an unrealised row an estimated height and replaces
        /// it with a measured one when the row is realised, which happens as it comes into view. An
        /// article row's real height is nothing like the estimate, so scrolling through RSS items
        /// grows the content above by thousands of points — measured at 96,938 → 104,601 over one
        /// short scroll.
        ///
        /// A scroll offset is a distance from the top of the content, so all of that growth moves
        /// what is on screen while the offset does not change at all. Which is why nothing saw it:
        /// no offset moved, so the movement log stayed silent, and no item arrived, so no hold was
        /// ever armed.
        ///
        /// ## Why this is a delta and not a position
        ///
        /// The first version of this restored a remembered `(row, offset)` pair, and it lurched the
        /// list 94 points against a reader who was mid-scroll. That approach cannot work: an offset
        /// is measured against the viewport, so a remembered one conflates where the layout moved
        /// the row with where the *reader* moved the viewport, and restoring it undoes both.
        ///
        /// So the measurement is taken in content coordinates instead, where the reader does not
        /// appear: ``noteContentResize()`` records how far the anchor row's top moved within the
        /// content, which only the layout can change. Scrolling by exactly that leaves the anchor
        /// where it was on screen and leaves the reader's own scrolling entirely alone.
        private func anchorContentResize() {
            let delta = pendingResizeDelta
            pendingResizeDelta = 0

            // A hold knows about an insertion this does not, so it wins outright.
            guard hold == nil, abs(delta) > ScrollAnchor.tolerance else { return }
            guard let table, let scrollView = table.enclosingScrollView else { return }

            let clip = scrollView.contentView
            ScrollDiagnostics.shared.attribute(String(format: "resize anchor delta=%+.1f", delta))
            clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
            ScrollDiagnostics.shared.attribute("resize anchor (reflect)")
            scrollView.reflectScrolledClipView(clip)
            ScrollDiagnostics.shared.clearAttribution()
            // Nothing to re-snapshot: scrolling moves the viewport, not the content, so the
            // anchor's top is exactly where ``noteContentResize()`` just recorded it.
        }

        /// Applies a correction at the top of the next run-loop turn rather than inside this one.
        ///
        /// ## Why this cannot be synchronous, however much the design wants it to be
        ///
        /// It was, and the intent was sound: land the correction in the same pass that brought the
        /// rows in and the displaced frame is never drawn. What it produced was a console full of
        ///
        /// > NSHostingView is being laid out reentrantly while rendering its SwiftUI content. This
        /// > is not supported and the current layout pass will be skipped.
        ///
        /// which is unavoidable rather than fixable. Scrolling a table view makes it lay out its
        /// rows; every row of a SwiftUI `List` *is* an `NSHostingView`; and both places the pin was
        /// applied from run inside SwiftUI's own layout — the table's frame-change notification is
        /// posted from it, and the arming happens in `onChange(of: items.count)`. So the pin asked
        /// AppKit to lay out a hosting view that was already being laid out, and AppKit's answer
        /// was to drop the pass.
        ///
        /// A dropped layout pass during an insertion is strictly worse than a late correction: the
        /// rows are then placed from geometry that never finished updating, which is the other half
        /// of the list jumping. Deferring costs at most one frame in which the rows sit low — and
        /// buys a delta computed against a table that has its new rows and their real heights,
        /// rather than one measured mid-update.
        ///
        /// Coalesced, because a change to the content produces a burst of geometry changes and
        /// they all want the same single correction.
        private func scheduleCorrection() {
            guard !correctionScheduled else { return }
            correctionScheduled = true
            // `RunLoop.main` rather than a `Task`, so this is also serviced while the run loop is
            // in an event-tracking mode — which is precisely when a refresh landing mid-scroll
            // needs it.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                // `RunLoop.main` runs what it is given on the main thread, which is the main actor
                // — but the closure is `@Sendable` and carries no isolation of its own, so the
                // compiler cannot see that and the `Handle`'s state is all main-actor. Asserted
                // rather than hopped through a `Task { @MainActor in … }`, which would give up the
                // one property this scheduling exists for: a run-loop block is serviced in
                // event-tracking mode, and a task is not, so a refresh landing mid-scroll would
                // have its correction held until the scroll ended.
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.correctionScheduled = false
                    self.applyCorrection()
                }
            }
        }

        /// Applies whichever correction is owed.
        ///
        /// A hold, when there is one, is the better-informed of the two: it was told the row's
        /// *new* index by the list. Otherwise the content changed shape without the item set
        /// changing, which is what the resize anchor is for.
        ///
        /// Called both from the table's own geometry pass and from the deferred pass above, and
        /// idempotent so that costs nothing: each correction consumes the thing that asks for it,
        /// so whichever runs first does the work and the other finds nothing owed.
        private func applyCorrection() {
            if hold != nil {
                pinIfHolding()
            } else {
                anchorContentResize()
            }
        }

        /// Starts listening to the table and its scroller.
        ///
        /// Registered when the table is resolved rather than on the first hold, and that ordering
        /// is load-bearing twice over. The live-scroll state has to be right already when a hold is
        /// armed *during* a scroll; and the content can change height with no hold ever being
        /// armed, which is the case ``anchorContentResize()`` exists for and which a
        /// registration made at arming time would never have seen at all. Re-tried from
        /// ``holdAnchor(row:offset:for:)`` anyway, for the case where the table was found before it
        /// had a scroll view.
        private func observeTable() {
            guard !scrolling.isRegistered, let table, let scrollView = table.enclosingScrollView else {
                return
            }

            // The content's own size. Scoped to this table — `object: nil` would deliver every view
            // geometry change in the app.
            table.postsFrameChangedNotifications = true
            let clipView = scrollView.contentView
            geometry.observeSynchronously(
                NSView.frameDidChangeNotification,
                object: table
            ) { [weak self] in
                ScrollDiagnostics.shared.content(
                    height: table.frame.height,
                    clipOrigin: clipView.bounds.origin.y,
                    fold: self?.foldReading
                )
                // Measured here, synchronously, because the row's previous position within the
                // content is only knowable before anything re-samples it.
                self?.noteContentResize()

                // ## Corrected here too, which reverses an earlier decision
                //
                // This used to only ever schedule, on the grounds that scrolling from inside a
                // layout pass makes AppKit complain about `NSHostingView` being laid out
                // reentrantly and skip the pass. That reasoning stands, but the cost turned out to
                // be the remaining symptom: a correction that lands a run-loop turn late lands
                // *after* a frame has been drawn, so the displacement is briefly visible — the
                // flicker. The jumps that deferring was meant to be protecting against turned out
                // to have entirely different causes, all of them since fixed.
                //
                // So the correction is attempted in the pass that caused the displacement, where
                // it cannot be seen, and the scheduled pass below stays as the net for whatever
                // the immediate attempt cannot do yet — a hold whose rows the table has not been
                // handed, most of all.
                self?.applyCorrection()
                self?.scheduleCorrection()
            }

            // Every movement of the list, whoever caused it; compiled to a no-op call in release
            // builds.
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            scrolling.observeSynchronously(NSView.boundsDidChangeNotification, object: clip) { [weak self] in
                ScrollDiagnostics.shared.movement(
                    to: clip.bounds.origin.y,
                    table: self?.table,
                    duringLiveScroll: self?.isLiveScrolling ?? false
                )
                // Re-anchored whenever the list moves, which is the only thing that changes *which*
                // row the top edge cuts through. The row's top is in content coordinates, so
                // scrolling does not invalidate the value — only the choice of row.
                self?.anchorSnapshot = self?.topRowSnapshot()
            }

            // The heartbeat, stamped and otherwise silent: it fires for every scroll event of a
            // gesture, momentum included, and logging each one would bury everything else. A flag
            // set on `willStart` and cleared on `didEnd` would stick permanently true if the end
            // were ever missed, and a correction that silently never runs again brings back the
            // twitch with nothing to point at.
            scrolling.observeSynchronously(
                NSScrollView.didLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.lastLiveScrollAt = Date()
            }

            // The edges, logged. Whether these arrive at all for a SwiftUI `List` is the assumption
            // the live-scroll state rests on, and it has never been checked.
            for (name, label) in [
                (NSScrollView.willStartLiveScrollNotification, "reader began scrolling"),
                (NSScrollView.didEndLiveScrollNotification, "reader stopped scrolling")
            ] {
                scrolling.observeSynchronously(name, object: scrollView) { [weak self] in
                    self?.lastLiveScrollAt = Date()
                    ScrollDiagnostics.shared.note(label)
                }
            }
        }
    }

    let handle: Handle

    func makeNSView(context: Context) -> NSView {
        ProbeView(handle: handle)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// A zero-size view whose only job is to find the table it has been planted behind.
    ///
    /// Planted **once**, in the list's background, rather than in each row. Attaching an
    /// `NSViewRepresentable` to every row's background is fatal on macOS 26: the window is created
    /// — it appears in the Window menu, correctly titled — but never displays, and the app sits
    /// there with a menu bar and nothing on screen. One probe costs nothing and avoids it.
    private final class ProbeView: NSView {

        private let handle: Handle

        init(handle: Handle) {
            self.handle = handle
            super.init(frame: .zero)
            MainActor.assumeIsolated {
                handle.resolve = { [weak self] in self?.resolveTable() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveTable()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveTable()
        }

        /// Re-tries the search once the probe has a real frame.
        ///
        /// Load-bearing, not belt-and-braces: planted in the list's background the probe is laid
        /// out *before* the list, so at `viewDidMoveToWindow` its frame is still empty and the
        /// overlap search has nothing to compare. Without this the table was never found at all
        /// and the fold silently stayed at whatever the stored position had been — the count
        /// simply stopped following the scroll.
        override func layout() {
            super.layout()
            if handle.table == nil { resolveTable() }
        }

        /// Finds the timeline's table.
        ///
        /// A list's background is not necessarily inside its scroll view, so `enclosingScrollView`
        /// is tried first and then the window is searched. The search is disambiguated by frame:
        /// the sidebar is a table too, so picking the first one found would track the wrong
        /// column. This probe is stretched behind the timeline, so the scroll view that overlaps
        /// it most is the timeline's.
        private func resolveTable() {
            guard window != nil else { return }
            guard handle.table == nil else { return }

            if let direct = enclosingScrollView?.documentView as? NSTableView {
                handle.table = direct
                return
            }

            guard let root = window?.contentView else { return }
            let mine = convert(bounds, to: nil)
            guard !mine.isEmpty else { return }

            var best: (table: NSTableView, overlap: CGFloat)?
            for scrollView in Self.scrollViews(in: root) {
                guard let table = scrollView.documentView as? NSTableView else { continue }
                let area = scrollView.convert(scrollView.bounds, to: nil).intersection(mine)
                let overlap = area.width * area.height
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (table, overlap)
            }
            if let best { handle.table = best.table }
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
#endif
