#if os(iOS)
import ReadReadModel
import SwiftUI
import UIKit

/// The timeline's list on iOS: a `UICollectionView` behind a representable.
///
/// Not a SwiftUI `List`, because the timeline needs three things `List` does not offer: an exact
/// reading of the fold, a way to replace the rows and put a given row at a given pixel in one
/// layout pass, and a clean separation between the reader's scrolling and every other cause of
/// movement. See ``TimelineSurface`` for the contract and ``TimelineController`` for what it is
/// used for.
///
/// The rows are still SwiftUI — ``ItemRow`` inside a `UIHostingConfiguration` — so swipe actions
/// and context menus are the same views as before.
struct TimelineCollection: UIViewRepresentable {

    let controller: TimelineController
    @Binding var selectedItemID: String?

    /// Changes whenever something the rows draw from changes, so the rows on screen are redrawn.
    let contentVersion: Int

    let rowContent: (CachedItem, Bool) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> TimelineCollectionView {
        let coordinator = context.coordinator
        coordinator.update(from: self, environment: context.environment)
        let view = coordinator.makeView()
        controller.attach(coordinator)
        return view
    }

    func updateUIView(_ view: TimelineCollectionView, context: Context) {
        context.coordinator.update(from: self, environment: context.environment)
    }

    static func dismantleUIView(_ view: TimelineCollectionView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TimelineSurface, UICollectionViewDelegate {

        let controller: TimelineController

        private var collectionView: TimelineCollectionView!
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

        private var rowContent: ((CachedItem, Bool) -> AnyView)?
        private var environment = EnvironmentValues()
        private var contentVersion: Int?
        private var selection: Binding<String?>?

        /// Rows whose item was deleted while this snapshot is on screen. See ``blank(rows:)``.
        private var blankedRows: [Int: CGFloat] = [:]

        /// Whether the reader has hold of the list.
        private var isUserScrolling = false

        /// Set while this coordinator selects a row itself, so the delegate does not write the
        /// selection straight back.
        private var isSyncingSelection = false

        private var hasRevealed = false
        private var hasShownSnapshot = false
        private var reportedViewport: Bool?

        /// The selected row as the separators were last drawn for it.
        private var drawnSelection: Int?

        /// What pull to refresh runs: the `.refreshable` action in the environment. A `List` picks
        /// it up on its own; a collection view has to be given a refresh control for it.
        private var refreshAction: RefreshAction?

        init(controller: TimelineController) {
            self.controller = controller
        }

        func makeView() -> TimelineCollectionView {
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            // Drawn by the rows instead — see `configure(_:row:itemID:)` and `RowSeparator`.
            configuration.showsSeparators = false
            let layout = UICollectionViewCompositionalLayout.list(using: configuration)

            let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.delegate = self
            view.alpha = 0
            view.allowsSelection = true
            view.onLayout = { [weak self] in self?.didLayout() }
            collectionView = view

            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
                [weak self] cell, indexPath, itemID in
                self?.configure(cell, row: indexPath.item, itemID: itemID)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, indexPath, itemID in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
            }
            return view
        }

        func update(from representable: TimelineCollection, environment: EnvironmentValues) {
            rowContent = representable.rowContent
            self.environment = environment
            selection = representable.$selectedItemID
            refreshAction = environment.refresh
            installRefreshControlIfNeeded()

            if let previous = contentVersion, previous != representable.contentVersion {
                reconfigureVisibleRows()
            }
            contentVersion = representable.contentVersion
            syncSelection()
        }

        // MARK: Cells

        private func configure(_ cell: UICollectionViewListCell, row: Int, itemID: String) {
            cell.backgroundConfiguration = .clear()

            if let height = blankedRows[row] {
                cell.configurationUpdateHandler = nil
                cell.contentConfiguration = UIHostingConfiguration { Color.clear.frame(height: height) }
                return
            }

            guard let item = controller.item(withID: itemID), let rowContent else {
                cell.configurationUpdateHandler = nil
                cell.contentConfiguration = UIHostingConfiguration { Color.clear.frame(height: 1) }
                return
            }

            let environment = environment
            let separatorInset = cell.directionalLayoutMargins.leading
            let makeContent = { [weak self] (isSelected: Bool) -> UIContentConfiguration in
                let showsSeparator = self?.showsSeparator(below: itemID) ?? false
                return UIHostingConfiguration {
                    rowContent(item, isSelected)
                        .environment(\.self, environment)
                }
                // Behind the whole cell rather than inside its margins, as a list row background
                // would be — so the separator sits on the cell's bottom edge, not above its margin.
                .background {
                    ZStack(alignment: .bottom) {
                        SelectionMarker(isSelected: isSelected)
                        if showsSeparator {
                            Divider()
                                .padding(.leading, separatorInset)
                        }
                    }
                }
            }
            // Set now as well as in the handler, so the cell has content when it is sized.
            cell.contentConfiguration = makeContent(cell.isSelected)
            cell.configurationUpdateHandler = { cell, state in
                cell.contentConfiguration = makeContent(state.isSelected)
            }
        }

        /// Asked when the cell is drawn rather than when it is configured, by item rather than by
        /// row: a cell keeps its item while rows are inserted above it, and its neighbours change.
        private func showsSeparator(below itemID: String) -> Bool {
            guard let row = controller.row(of: itemID) else { return false }
            return RowSeparator.isShown(
                below: row,
                count: controller.snapshot.count,
                selectedRow: collectionView.indexPathsForSelectedItems?.first?.item
            )
        }

        /// Redraws the separators of rows on screen — all of them, or those next to a selection
        /// that moved.
        private func redrawSeparators(rows: Set<Int>? = nil) {
            let targets = rows.map { rows in rows.map { IndexPath(item: $0, section: 0) } }
                ?? collectionView.indexPathsForVisibleItems
            for indexPath in targets {
                collectionView.cellForItem(at: indexPath)?.setNeedsUpdateConfiguration()
            }
        }

        private func selectionChanged() {
            let selected = collectionView.indexPathsForSelectedItems?.first?.item
            guard selected != drawnSelection else { return }
            let rows = RowSeparator.rowsAffected(bySelectionChangeFrom: drawnSelection, to: selected)
            drawnSelection = selected
            redrawSeparators(rows: rows)
        }

        // MARK: Pull to refresh

        private func installRefreshControlIfNeeded() {
            guard let collectionView, refreshAction != nil, collectionView.refreshControl == nil else { return }
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
            collectionView.refreshControl = control
        }

        @objc private func pulledToRefresh() {
            guard let refreshAction else {
                collectionView.refreshControl?.endRefreshing()
                return
            }
            Task { [weak self] in
                await refreshAction()
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }

        // MARK: Selection

        private func syncSelection() {
            guard let collectionView, hasShownSnapshot else { return }
            let wanted = controller.row(of: selection?.wrappedValue)
            let current = collectionView.indexPathsForSelectedItems?.first?.item
            guard wanted != current else { return }

            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if let current {
                collectionView.deselectItem(at: IndexPath(item: current, section: 0), animated: false)
            }
            if let wanted {
                // No scroll position: selecting from the reading pane must not move the list.
                collectionView.selectItem(at: IndexPath(item: wanted, section: 0), animated: false, scrollPosition: [])
            }
            selectionChanged()
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            selectionChanged()
            guard !isSyncingSelection else { return }
            selection?.wrappedValue = controller.itemID(at: indexPath.item)
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            selectionChanged()
            guard !isSyncingSelection else { return }
            if selection?.wrappedValue == controller.itemID(at: indexPath.item) {
                selection?.wrappedValue = nil
            }
        }

        // MARK: Scrolling

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userBegan()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isUserScrolling else { return }
            controller.surfaceFoldMoved()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { userEnded() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            userEnded()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            // Tapping the status bar is the reader asking for the top.
            userBegan()
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            userEnded()
        }

        private func userBegan() {
            guard !isUserScrolling else { return }
            isUserScrolling = true
            collectionView.pinned = nil
            controller.surfaceUserBegan()
        }

        private func userEnded() {
            guard isUserScrolling else { return }
            isUserScrolling = false
            // From here until the next scroll, this is where the list stays.
            collectionView.pinned = foldReading()
            controller.surfaceUserEnded()
        }

        private func didLayout() {
            let hasSize = hasViewport
            if hasSize != reportedViewport {
                reportedViewport = hasSize
                controller.surfaceDidChangeViewport(hasSize: hasSize)
            }

            // Revealed once the first snapshot has been laid out at its placement — the pin has
            // already run in this pass, so what becomes visible is the position, not the top.
            if !hasRevealed, hasSize, hasShownSnapshot {
                hasRevealed = true
                collectionView.alpha = 1
                controller.surfaceDidReveal()
            }
        }

        // MARK: TimelineSurface

        var hasViewport: Bool {
            guard let collectionView else { return false }
            return collectionView.bounds.height > 0 && collectionView.bounds.width > 0
        }

        func show(_ snapshot: TimelineSnapshot, placing placement: FoldReading?) {
            blankedRows = [:]
            var rows = NSDiffableDataSourceSnapshot<Int, String>()
            rows.appendSections([0])
            rows.appendItems(snapshot.rows.map(\.id))

            collectionView.pinned = placement
            UIView.performWithoutAnimation {
                dataSource.apply(rows, animatingDifferences: false)
                collectionView.layoutIfNeeded()
            }
            hasShownSnapshot = true
            syncSelection()
            // Which row is last, and which rows neighbour the selection, may have changed.
            drawnSelection = collectionView.indexPathsForSelectedItems?.first?.item
            redrawSeparators()
        }

        func place(_ placement: FoldReading) {
            collectionView.pinned = placement
            UIView.performWithoutAnimation {
                collectionView.setNeedsLayout()
                collectionView.layoutIfNeeded()
            }
        }

        func scrollRowToVisible(_ row: Int) {
            guard let frame = collectionView.frameOfRow(row) else { return }
            let top = collectionView.visibleTop
            let bottom = collectionView.contentOffset.y + collectionView.bounds.height
                - collectionView.adjustedContentInset.bottom
            if frame.minY < top {
                place(FoldReading(row: row, offset: 0))
            } else if frame.maxY > bottom {
                collectionView.setContentOffsetClamped(frame.maxY - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom)
                collectionView.pinned = foldReading()
            }
        }

        func foldReading() -> FoldReading? {
            collectionView?.foldReading()
        }

        func visibleRows() -> Range<Int>? {
            guard let fold = foldReading() else { return nil }
            let last = collectionView.indexPathsForVisibleItems.map(\.item).max() ?? fold.row
            return fold.row..<(max(last, fold.row) + 1)
        }

        func reconfigureVisibleRows() {
            guard let dataSource, hasShownSnapshot else { return }
            var rows = dataSource.snapshot()
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            rows.reconfigureItems(visible)
            UIView.performWithoutAnimation {
                dataSource.apply(rows, animatingDifferences: false)
            }
        }

        /// Nothing to forget: a hosting configuration observes its item and resizes its cell itself.
        func invalidate(itemIDs: Set<String>) {}

        func blank(rows: [Int]) {
            var changed: [String] = []
            for row in rows {
                guard let cell = collectionView.cellForItem(at: IndexPath(item: row, section: 0)),
                      let itemID = controller.itemID(at: row) else { continue }
                blankedRows[row] = cell.bounds.height
                changed.append(itemID)
            }
            guard !changed.isEmpty else { return }
            var current = dataSource.snapshot()
            current.reconfigureItems(changed)
            UIView.performWithoutAnimation {
                dataSource.apply(current, animatingDifferences: false)
            }
        }
    }
}

/// A collection view that keeps its fold where it was put.
///
/// Two corrections, both applied inside the layout pass so nothing is ever drawn out of place:
///
/// - **Pinned, while nobody scrolls.** ``pinned`` names a row and its offset from the top edge,
///   and every layout pass puts it back there — after rows size themselves, images arrive, the
///   width changes or new rows are applied.
/// - **Compensated, while the reader scrolls.** Rows above the fold have only estimated heights
///   until they come into view. When one is measured, everything below it moves; the pass measures
///   how far the fold row moved on screen and scrolls by the same amount, so it does not.
final class TimelineCollectionView: UICollectionView {

    var pinned: FoldReading?

    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        let before = isTracking || isDecelerating ? foldScreenPosition() : nil
        super.layoutSubviews()

        if let before, let after = screenPosition(ofRow: before.row) {
            let drift = after - before.y
            if abs(drift) > 0.5 {
                contentOffset.y += drift
            }
        } else {
            pin()
        }
        onLayout?()
    }

    /// The top of the viewport in content coordinates: under the bars, not behind them.
    var visibleTop: CGFloat {
        contentOffset.y + adjustedContentInset.top
    }

    func frameOfRow(_ row: Int) -> CGRect? {
        guard row >= 0, row < numberOfItems(inSection: 0) else { return nil }
        return collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame
    }

    func foldReading() -> FoldReading? {
        guard bounds.height > 0, numberOfSections > 0, numberOfItems(inSection: 0) > 0 else { return nil }
        let top = visibleTop

        // The row intruding into the top edge: the first visible row whose bottom is below it.
        var best: (row: Int, minY: CGFloat)?
        for indexPath in indexPathsForVisibleItems {
            guard let frame = frameOfRow(indexPath.item), frame.maxY > top else { continue }
            if best == nil || frame.minY < best!.minY {
                best = (indexPath.item, frame.minY)
            }
        }
        if best == nil, let path = indexPathForItem(at: CGPoint(x: bounds.midX, y: top + 1)),
           let frame = frameOfRow(path.item) {
            best = (path.item, frame.minY)
        }
        guard let best else { return nil }
        // Never below the top edge: that only happens while the list is pulled down past its top,
        // and holding the first row there would leave the gap open once the pull is let go.
        return FoldReading(row: best.row, offset: min(best.minY - top, 0))
    }

    private func foldScreenPosition() -> (row: Int, y: CGFloat)? {
        guard let fold = foldReading(), let y = screenPosition(ofRow: fold.row) else { return nil }
        return (fold.row, y)
    }

    private func screenPosition(ofRow row: Int) -> CGFloat? {
        frameOfRow(row).map { $0.minY - contentOffset.y }
    }

    private func pin() {
        guard let pinned, !isTracking, !isDecelerating, bounds.height > 0,
              let frame = frameOfRow(pinned.row) else { return }
        let target = frame.minY - pinned.offset - adjustedContentInset.top
        if abs(contentOffset.y - target) > 0.5 {
            setContentOffsetClamped(target)
        }
    }

    func setContentOffsetClamped(_ y: CGFloat) {
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let clamped = min(max(y, minY), maxY)
        guard abs(contentOffset.y - clamped) > 0.5 else { return }
        contentOffset.y = clamped
    }
}
#endif
