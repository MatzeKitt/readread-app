#if os(iOS)
import SwiftUI
import UIKit

/// Reports which row sits at the top of a `List`'s viewport, on iOS.
///
/// The counterpart to the AppKit `TimelineFoldReader`, and built the same way for the same reason.
/// The macOS file's comment says iOS "gets the pure-SwiftUI path in its own pass" — that was a
/// guess written before this pass, and it is not worth relying on: every SwiftUI scroll API except
/// `onScrollGeometryChange` proved unusable for this on macOS, and a reading position that
/// silently stops updating is the failure mode this whole design is trying to avoid. Asking the
/// backing view which row is at a point cannot go stale.
///
/// Without it, iPhone never wrote a reading position at all: `readFold()` was compiled out, so the
/// fold stayed `nil`, `commitPosition()` had nothing to write, and the device could only ever
/// receive positions from macOS — one half of the app's central promise missing on one platform.
struct TimelineFoldReader: UIViewRepresentable {

    /// Holds the collection view weakly, so nothing here keeps a dead view alive.
    @MainActor
    final class Handle {

        weak var collectionView: UICollectionView?

        /// Asks the probe to look for the collection view again.
        var resolve: (() -> Void)?

        /// One reading of the fold: which row it is, and where it sits.
        ///
        /// Both from a single look at the geometry, deliberately — two calls can disagree, and a
        /// scroll between them attributes one row's offset to another.
        ///
        /// - The **row** is the first one *entirely* below the top edge of the viewport. Entirely,
        ///   not merely intersecting — see the AppKit reader for why. The count beside the list is
        ///   how many items sit above the fold, so a row still cut off by the top edge has not
        ///   been read and must keep counting.
        /// - The **offset** is how far below that edge its top sits, which is what
        ///   ``holdAnchor(row:offset:for:)`` puts it back to.
        var foldReading: (row: Int, offset: CGFloat)? {
            if collectionView == nil { resolve?() }
            guard let collectionView else { return nil }
            guard collectionView.numberOfSections > 0,
                  collectionView.numberOfItems(inSection: 0) > 0 else { return nil }

            // The top of what the reader can actually see, in content coordinates. The adjusted
            // inset is what accounts for the navigation bar and the scroll-edge effect; measuring
            // from the raw offset would put the fold underneath the bar, where nothing is legible.
            let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top

            // Written as a single pass over the visible cells rather than `sorted()` plus a search.
            // This runs on a scrolling list, and sorting an array to pick its minimum is the kind
            // of allocation that only shows up as heat.
            var lowest: IndexPath?
            var highest: IndexPath?
            var firstWhole: IndexPath?

            for path in collectionView.indexPathsForVisibleItems {
                if lowest == nil || path < lowest! { lowest = path }
                if highest == nil || path > highest! { highest = path }

                guard let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { continue }
                // The whole cell is below the edge, so this one has actually been shown.
                guard frame.minY >= top - Self.edgeTolerance else { continue }
                if firstWhole == nil || path < firstWhole! { firstWhole = path }
            }

            guard let lowest, let highest else { return nil }

            // Bounced above the top: the first row is fully on screen by definition.
            let path = top <= 0 ? lowest : (firstWhole ?? highest)
            let row = flatRow(of: path, in: collectionView)
            let cellTop = collectionView.layoutAttributesForItem(at: path)?.frame.minY ?? top
            return (row, cellTop - top)
        }

        /// The fold row alone, for the callers that do not care where it sits.
        var foldRow: Int? { foldReading?.row }

        /// Slack when deciding whether a cell's top is above the viewport's.
        ///
        /// Both numbers land on fractional pixels, so an exactly aligned cell compares as a hair
        /// above the edge about half the time — and the count would flicker while the list sits
        /// perfectly still.
        private static let edgeTolerance: CGFloat = 0.5

        /// The row's index across the whole list.
        ///
        /// The timeline is one flat `ForEach`, so this is nearly always `indexPath.item` — but the
        /// fold *is* the count of items above it, and a section header quietly appearing would
        /// make that number wrong rather than make it fail.
        private func flatRow(of indexPath: IndexPath, in collectionView: UICollectionView) -> Int {
            guard indexPath.section > 0 else { return indexPath.item }
            var offset = 0
            for section in 0..<indexPath.section {
                offset += collectionView.numberOfItems(inSection: section)
            }
            return offset + indexPath.item
        }

        // MARK: - Holding the anchor

        /// A row being kept where it is while rows land above it.
        private struct Hold {
            var row: Int
            var offset: CGFloat
            var expiresAt: Date
        }

        private var hold: Hold?

        /// Owns the content-size observation, so it can be torn down from a nonisolated `deinit`.
        private var sizeObservation: NSKeyValueObservation?

        /// Owns the content-offset observation, which keeps the anchor pointed at the right cell.
        ///
        /// The counterpart to the AppKit reader watching its clip view's bounds: scrolling is the
        /// only thing that changes *which* cell the top edge cuts through, and the snapshot has to
        /// be right before a resize rather than after it.
        private var offsetObservation: NSKeyValueObservation?

        /// A row and where its top sits in the **content**, as the reference for a resize.
        ///
        /// Content coordinates, not screen ones, which is what makes a correction possible at all:
        /// a cell's top only moves when the layout above it changes, so the reader scrolling does
        /// not invalidate a snapshot however much they scroll after it was taken. See the AppKit
        /// reader for the version of this that measured against the viewport instead, and what it
        /// did to a reader mid-scroll.
        private var anchorSnapshot: (row: Int, rowTop: CGFloat)?

        /// Growth above the anchor that has not been compensated for yet.
        private var pendingResizeDelta: CGFloat = 0

        /// The cell the top edge of the viewport cuts through, and where its top sits.
        ///
        /// The straddling cell rather than the fold, for the reason the AppKit reader sets out at
        /// length: the fold is one row below the top edge, so anchoring on it treats the growth of
        /// the row being realised — which is always the one coming into view — as growth off
        /// screen, and compensates for a displacement that never happened.
        private func topRowSnapshot() -> (row: Int, rowTop: CGFloat)? {
            guard let collectionView else { return nil }
            let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            guard let path = collectionView.indexPathForItem(at: CGPoint(x: 0, y: max(top, 0))),
                  let rowTop = collectionView.layoutAttributesForItem(at: path)?.frame.minY
            else {
                return nil
            }
            return (flatRow(of: path, in: collectionView), rowTop)
        }

        /// Measures how far the anchor moved within the content, at the moment it moved.
        private func noteContentResize() {
            // Nothing to measure against yet — the list has not moved since it appeared.
            // Taking the snapshot now means the *next* resize is corrected rather than this
            // one, which is the honest answer: the previous position genuinely is not known.
            guard anchorSnapshot != nil else {
                anchorSnapshot = topRowSnapshot()
                return
            }
            guard hold == nil, let snapshot = anchorSnapshot, let collectionView else { return }
            guard let path = indexPath(forRow: snapshot.row, in: collectionView),
                  let rowTop = collectionView.layoutAttributesForItem(at: path)?.frame.minY
            else {
                anchorSnapshot = nil
                return
            }

            anchorSnapshot = (snapshot.row, rowTop)
            let growth = rowTop - snapshot.rowTop
            guard abs(growth) > ScrollAnchor.tolerance else { return }
            pendingResizeDelta += growth
        }

        /// Scrolls by however far the content above the anchor grew, so the anchor stays put.
        ///
        /// The counterpart to the AppKit reader's, and there for the same case: a `List` gives an
        /// unrealised row an estimated height and replaces it with a measured one as the row comes
        /// into view, so the content above the viewport grows while the content offset — a distance
        /// from the top of that content — does not move at all. No hold is armed for it, because no
        /// items arrived.
        ///
        /// A delta measured in content coordinates rather than a remembered screen position, for
        /// the reason the AppKit reader sets out at length.
        private func anchorContentResize() {
            let delta = pendingResizeDelta
            pendingResizeDelta = 0

            // A hold knows about an insertion this does not, so it wins outright.
            guard hold == nil, abs(delta) > ScrollAnchor.tolerance, let collectionView else { return }

            // Left in place on this platform, unlike on the Mac: a delta correction is safe under a
            // gesture, but `setContentOffset` during deceleration stops the deceleration, and iOS
            // has not shown the problem this exists to fix. Worth revisiting together with the Mac's
            // behaviour once that is settled.
            guard !collectionView.isTracking,
                  !collectionView.isDragging,
                  !collectionView.isDecelerating
            else {
                return
            }

            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: collectionView.contentOffset.y + delta),
                animated: false
            )
        }

        /// Keeps `row` at `offset` below the top edge for a short while.
        ///
        /// The counterpart to the AppKit reader's hold and armed by the same caller, for the reason
        /// spelled out in ``ScrollAnchor``: a refresh prepends rows, a scroll view keeps its
        /// offset, and correcting that from a `ScrollViewProxy` a frame later is visible as a
        /// twitch. Applied from the collection view's own content-size change, which happens in
        /// the layout pass that brought the rows in.
        ///
        /// - Parameters:
        ///   - row: Where the held item sits in the **new** list, which the caller knows before the
        ///     collection view does.
        ///   - duration: How long to keep correcting, kept short so a reader who scrolls the
        ///     instant items land is not fighting the pin.
        func holdAnchor(row: Int, offset: CGFloat, for duration: TimeInterval) {
            hold = Hold(row: row, offset: offset, expiresAt: Date(timeIntervalSinceNow: duration))
            observeContentSize()
            pinIfHolding()
        }

        func releaseAnchor() {
            hold = nil
        }

        /// Whether the reader has hold of the list.
        ///
        /// Exposed so the list can tell a fold that moved because items arrived from one that moved
        /// because the reader moved it — see ``FoldHold``. `isDecelerating` counts: a flick has
        /// ended the drag but the reader is still the one moving the list.
        var isReaderScrolling: Bool {
            guard let collectionView else { return false }
            return collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        }

        /// Applies the correction, if one is being held and the collection view can be asked yet.
        ///
        /// - Returns: Whether the hold could be applied. `false` while the collection view still
        ///   has the old cells, which is the ordinary case at the moment a hold is armed.
        @discardableResult
        func pinIfHolding() -> Bool {
            guard let hold else { return false }
            guard Date() < hold.expiresAt else {
                releaseAnchor()
                return false
            }
            guard let collectionView else { return false }

            // The reader has a finger on the list, or has just taken it off and the list is still
            // running. Their scroll outranks any hold: pinning under a gesture fights it, and the
            // fight reads as the list jumping a couple of rows back towards the top.
            //
            // `isDecelerating` alongside the other two, because a flick ends the drag while the
            // list keeps moving — and a refresh landing in that stretch found no finger down and
            // pinned against the momentum.
            guard !collectionView.isTracking,
                  !collectionView.isDragging,
                  !collectionView.isDecelerating
            else {
                releaseAnchor()
                return false
            }

            guard let path = indexPath(forRow: hold.row, in: collectionView),
                  let rowTop = collectionView.layoutAttributesForItem(at: path)?.frame.minY
            else {
                // Not laid out yet. Nothing to do but wait to be asked again, from the content-size
                // change a moment from now.
                return false
            }

            let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            guard let delta = ScrollAnchor.correction(
                rowTop: rowTop,
                offset: hold.offset,
                viewportTop: top
            ) else {
                // Already where it should be, which is a successful hold rather than a failed one.
                return true
            }

            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: collectionView.contentOffset.y + delta),
                animated: false
            )
            return true
        }

        /// The path for a flat row index, inverting ``flatRow(of:in:)``.
        private func indexPath(forRow row: Int, in collectionView: UICollectionView) -> IndexPath? {
            guard row >= 0 else { return nil }
            var remaining = row
            for section in 0..<collectionView.numberOfSections {
                let count = collectionView.numberOfItems(inSection: section)
                if remaining < count { return IndexPath(item: remaining, section: section) }
                remaining -= count
            }
            return nil
        }

        /// Starts watching the collection view's content size.
        ///
        /// The size is what changes when rows are inserted, and it changes *within* the layout pass
        /// that inserts them — which is the only moment at which a correction is invisible. A
        /// notification hop or a `Task` would land a turn later, by which point the displaced frame
        /// has been drawn, and that frame is the bug being fixed.
        ///
        /// Registered once, on the first hold, and left in place: ``pinIfHolding()`` is a `nil`
        /// check when nothing is held.
        private func observeContentSize() {
            guard sizeObservation == nil, let collectionView else { return }

            offsetObservation = collectionView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.anchorSnapshot = self?.topRowSnapshot() }
            }
            sizeObservation = collectionView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                // UIKit mutates this on the main thread, and `MainActor.assumeIsolated` off it is
                // not an error but a `SIGTRAP` — see `NotificationRegistration.observe`. If it
                // ever arrives elsewhere the pin is skipped and the caller's retries cover it.
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.noteContentResize()
                    // A hold is the better-informed of the two — it was told the row's *new* index
                    // by the list. Without one, the content changed shape while the item set stayed
                    // as it was, which is what the resize anchor is for.
                    if self.pinIfHolding() { return }
                    self.anchorContentResize()
                }
            }
        }
    }

    let handle: Handle

    func makeUIView(context: Context) -> UIView {
        ProbeView(handle: handle)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// A zero-size view whose only job is to find the collection view it has been planted behind.
    private final class ProbeView: UIView {

        private let handle: Handle

        init(handle: Handle) {
            self.handle = handle
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            MainActor.assumeIsolated {
                handle.resolve = { [weak self] in self?.resolveCollectionView() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveCollectionView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The probe sits in the list's background and is laid out before the list, so at
            // `didMoveToWindow` its frame is still empty and the overlap search has nothing to
            // compare. The macOS probe needed exactly the same retry.
            if handle.collectionView == nil { resolveCollectionView() }
        }

        private func resolveCollectionView() {
            guard window != nil, handle.collectionView == nil else { return }

            // Walking up first: the background is usually inside the list's own scroll view, and
            // when it is, this is exact and needs no disambiguation.
            var ancestor = superview
            while let view = ancestor {
                if let collectionView = view as? UICollectionView {
                    handle.collectionView = collectionView
                    return
                }
                ancestor = view.superview
            }

            guard let root = window else { return }
            let mine = convert(bounds, to: nil)
            guard !mine.isEmpty else { return }

            // Disambiguated by frame, as on macOS: on iPad the sidebar is a collection view too,
            // and taking the first one found would track the wrong column.
            var best: (view: UICollectionView, overlap: CGFloat)?
            for candidate in Self.collectionViews(in: root) {
                let area = candidate.convert(candidate.bounds, to: nil).intersection(mine)
                let overlap = area.width * area.height
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (candidate, overlap)
            }
            if let best { handle.collectionView = best.view }
        }

        private static func collectionViews(in view: UIView) -> [UICollectionView] {
            var found: [UICollectionView] = []
            if let collectionView = view as? UICollectionView { found.append(collectionView) }
            for subview in view.subviews {
                found.append(contentsOf: collectionViews(in: subview))
            }
            return found
        }
    }
}
#endif
