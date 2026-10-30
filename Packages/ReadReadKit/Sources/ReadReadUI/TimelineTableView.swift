#if os(macOS)
import AppKit
import ReadReadModel
import SwiftUI

/// The timeline's list on macOS: an `NSTableView` behind a representable.
///
/// The counterpart of `TimelineCollection` on iOS, for the same reasons — see there and
/// ``TimelineSurface``. Rows are SwiftUI views in `NSHostingView`s.
///
/// ## Why the rows are measured here
///
/// Not by `usesAutomaticRowHeights`. That sizes a row from its cell's Auto Layout fitting size, and
/// an `NSHostingView` reports a height for its *ideal* width — one long unwrapped line — rather
/// than for the column it sits in. Every row whose text wraps got a row a few lines short, and was
/// drawn clipped at top and bottom: a post lost its first and last lines, an article's three-line
/// excerpt came out as one.
///
/// So each row is measured for the table's actual width by a sizing controller, once, and cached
/// per item. Rows not measured yet get an estimate — the mean of the rows that have been — and are
/// measured just before they come into view, with the fold held still while their heights change.
/// That is the same estimated-then-exact scheme `UICollectionView` uses on iOS.
///
/// The table never becomes first responder. Keyboard focus stays with SwiftUI, on the focusable
/// view that wraps this, so the arrow keys and the configured shortcuts are handled by the same
/// `onKeyPress` handlers as everywhere else in the app instead of by `NSTableView`'s own
/// keyboard handling and type-select.
struct TimelineTable: NSViewRepresentable {

    let controller: TimelineController
    @Binding var selectedItemID: String?

    /// Changes whenever something the rows draw from changes, so the rows on screen are redrawn.
    let contentVersion: Int

    let rowContent: (CachedItem, Bool) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> TimelineScrollView {
        let coordinator = context.coordinator
        coordinator.update(from: self, environment: context.environment)
        let view = coordinator.makeView()
        controller.attach(coordinator)
        return view
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
        context.coordinator.update(from: self, environment: context.environment)
    }

    static func dismantleNSView(_ view: TimelineScrollView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TimelineSurface, NSTableViewDataSource, NSTableViewDelegate {

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("TimelineRow")

        /// The estimate before any row has been measured.
        private static let fallbackRowHeight: CGFloat = 88

        /// How long after the last scroll event the reader counts as having let go.
        ///
        /// A mouse wheel sends discrete events with no end, unlike a trackpad gesture, so the end
        /// of an interaction can only be inferred from the events stopping.
        private static let scrollEndDelay: TimeInterval = 0.2

        let controller: TimelineController

        private var scrollView: TimelineScrollView!
        private var tableView: TimelineTableView!

        private var rowContent: ((CachedItem, Bool) -> AnyView)?
        private var environment = EnvironmentValues()
        private var contentVersion: Int?
        private var selection: Binding<String?>?

        private var rowCount = 0
        private var blankedRows: [Int: CGFloat] = [:]

        /// Measured row heights by item id, valid for ``measuredWidth`` and ``measuredVersion``.
        private var heights: [String: CGFloat] = [:]
        private var measuredWidth: CGFloat = 0
        private var measuredVersion: Int?
        private var heightTotal: CGFloat = 0
        private var isMeasuring = false

        /// Measures rows off screen. Reused, because building a hosting controller per row would
        /// cost more than the measuring.
        private lazy var sizingController = NSHostingController(rootView: AnyView(EmptyView()))

        private var isUserScrolling = false
        private var isLiveScrolling = false
        private var scrollEndTimer: Timer?

        private var isSyncingSelection = false
        private var hasRevealed = false
        private var hasShownSnapshot = false
        private var reportedViewport: Bool?

        /// The row drawn as selected, so a selection change redraws two rows rather than all of them.
        private var drawnSelection = -1

        init(controller: TimelineController) {
            self.controller = controller
        }

        func makeView() -> TimelineScrollView {
            let table = TimelineTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Item"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            // Plain, so a cell is exactly as wide as the table and is measured at that width.
            // The row draws its own inset — see `TimelineContent.rowView`.
            table.style = .plain
            table.usesAutomaticRowHeights = false
            table.rowHeight = Self.fallbackRowHeight
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.selectionHighlightStyle = .none
            table.allowsTypeSelect = false
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.refusesFirstResponder = true
            table.backgroundColor = .clear
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            tableView = table

            let scroll = TimelineScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.automaticallyAdjustsContentInsets = true
            scroll.alphaValue = 0
            scroll.onScrollWheel = { [weak self] in self?.scrollWheelMoved() }
            scrollView = scroll

            table.onLayout = { [weak self] in self?.didLayout() }
            table.isReaderScrolling = { [weak self] in self?.isUserScrolling ?? false }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            return scroll
        }

        func update(from representable: TimelineTable, environment: EnvironmentValues) {
            rowContent = representable.rowContent
            self.environment = environment
            selection = representable.$selectedItemID

            let changed = contentVersion.map { $0 != representable.contentVersion } ?? false
            contentVersion = representable.contentVersion
            if changed {
                reconfigureVisibleRows()
            }
            syncSelection()
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if let height = blankedRows[row] { return height }
            if let id = controller.itemID(at: row), let height = heights[id] { return height }
            return estimatedRowHeight
        }

        private var estimatedRowHeight: CGFloat {
            heights.isEmpty ? Self.fallbackRowHeight : heightTotal / CGFloat(heights.count)
        }

        /// Drops every measurement when what they were measured for has changed.
        private func invalidateMeasurementsIfNeeded() {
            let width = tableView.bounds.width.rounded()
            guard width != measuredWidth || contentVersion != measuredVersion else { return }
            measuredWidth = width
            measuredVersion = contentVersion
            guard !heights.isEmpty else { return }
            heights = [:]
            heightTotal = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rowCount))
            }
        }

        /// Measures the rows on screen and a screen's height either side, so a row has its real
        /// height before it is drawn.
        ///
        /// Holds the fold where it is while heights change: rows measured above it would otherwise
        /// push it down the screen.
        ///
        /// - Returns: Whether any row changed height.
        @discardableResult
        private func measureRowsNearViewport() -> Bool {
            guard !isMeasuring, rowCount > 0, let scrollView, tableView.bounds.width > 0 else { return false }
            isMeasuring = true
            defer { isMeasuring = false }

            invalidateMeasurementsIfNeeded()

            let clip = scrollView.contentView.bounds
            let rect = NSRect(x: 0, y: clip.minY - clip.height, width: tableView.bounds.width, height: clip.height * 3)
            var changed = IndexSet()
            for row in tableView.rows(in: rect).asRange {
                guard blankedRows[row] == nil, let id = controller.itemID(at: row), heights[id] == nil else {
                    continue
                }
                let previous = tableView.rect(ofRow: row).height
                let height = measure(row: row)
                heights[id] = height
                heightTotal += height
                if abs(height - previous) > 0.5 { changed.insert(row) }
            }
            guard !changed.isEmpty else { return false }

            let before = isUserScrolling ? tableView.foldScreenPosition() : nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
            tableView.correct(from: before)
            return true
        }

        private func measure(row: Int) -> CGFloat {
            sizingController.rootView = content(forRow: row, isSelected: false)
            let size = sizingController.sizeThatFits(in: NSSize(width: tableView.bounds.width, height: .greatestFiniteMagnitude))
            return max(1, size.height.rounded(.up))
        }

        /// Forgets the heights of rows whose items changed, and measures again those near the screen.
        func invalidate(itemIDs: Set<String>) {
            var touched = false
            for id in itemIDs {
                if let height = heights.removeValue(forKey: id) {
                    heightTotal -= height
                    touched = true
                }
            }
            guard touched else { return }
            measureRowsNearViewport()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? HostingCell
                ?? HostingCell(identifier: Self.cellIdentifier)
            cell.host.rootView = content(forRow: row, isSelected: tableView.selectedRow == row)
            return cell
        }

        private func content(forRow row: Int, isSelected: Bool) -> AnyView {
            if let height = blankedRows[row] {
                return AnyView(Color.clear.frame(height: height))
            }
            guard let item = controller.item(at: row), let rowContent else {
                return AnyView(Color.clear.frame(height: 1))
            }
            let showsSeparator = RowSeparator.isShown(
                below: row,
                count: rowCount,
                selectedRow: tableView.selectedRow >= 0 ? tableView.selectedRow : nil
            )
            return AnyView(
                rowContent(item, isSelected)
                    .environment(\.self, environment)
                    // Inset like the row's selection marker. An overlay, so it takes no height and
                    // the measured heights do not depend on which rows show one.
                    .overlay(alignment: .bottom) {
                        if showsSeparator {
                            Divider()
                                .padding(.horizontal, 10)
                        }
                    }
            )
        }

        private func refresh(rows: IndexSet) {
            for row in rows where row < rowCount {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostingCell else {
                    continue
                }
                cell.host.rootView = content(forRow: row, isSelected: tableView.selectedRow == row)
            }
        }

        // MARK: Selection

        private func syncSelection() {
            guard let tableView, hasShownSnapshot else { return }
            let wanted = controller.row(of: selection?.wrappedValue) ?? -1
            guard wanted != tableView.selectedRow else { return }

            isSyncingSelection = true
            if wanted >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
            isSyncingSelection = false
            redrawSelection()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            redrawSelection()
            guard !isSyncingSelection else { return }
            let row = tableView.selectedRow
            selection?.wrappedValue = row >= 0 ? controller.itemID(at: row) : nil
        }

        private func redrawSelection() {
            let selected = tableView.selectedRow
            guard selected != drawnSelection else { return }
            let rows = RowSeparator.rowsAffected(
                bySelectionChangeFrom: drawnSelection >= 0 ? drawnSelection : nil,
                to: selected >= 0 ? selected : nil
            )
            drawnSelection = selected
            refresh(rows: IndexSet(rows))
        }

        // MARK: Scrolling

        private func scrollWheelMoved() {
            userBegan()
            scheduleScrollEnd()
        }

        @objc private func liveScrollStarted() {
            isLiveScrolling = true
            userBegan()
        }

        @objc private func liveScrollEnded() {
            isLiveScrolling = false
            scheduleScrollEnd()
        }

        @objc private func boundsChanged() {
            measureRowsNearViewport()
            guard isUserScrolling else { return }
            controller.surfaceFoldMoved()
        }

        private func scheduleScrollEnd() {
            scrollEndTimer?.invalidate()
            scrollEndTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollEndDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isLiveScrolling else { return }
                    self.userEnded()
                }
            }
        }

        private func userBegan() {
            guard !isUserScrolling else { return }
            isUserScrolling = true
            tableView.pinned = nil
            controller.surfaceUserBegan()
        }

        private func userEnded() {
            guard isUserScrolling else { return }
            isUserScrolling = false
            tableView.pinned = foldReading()
            controller.surfaceUserEnded()
        }

        private func didLayout() {
            measureRowsNearViewport()
            let hasSize = hasViewport
            if hasSize != reportedViewport {
                reportedViewport = hasSize
                controller.surfaceDidChangeViewport(hasSize: hasSize)
            }
            if !hasRevealed, hasSize, hasShownSnapshot {
                hasRevealed = true
                scrollView.alphaValue = 1
                controller.surfaceDidReveal()
            }
        }

        // MARK: TimelineSurface

        var hasViewport: Bool {
            guard let scrollView else { return false }
            return scrollView.contentView.bounds.height > 0 && scrollView.contentView.bounds.width > 0
        }

        func show(_ snapshot: TimelineSnapshot, placing placement: FoldReading?) {
            blankedRows = [:]
            drawnSelection = -1
            rowCount = snapshot.count
            tableView.pinned = placement
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.reloadData()
                tableView.layoutSubtreeIfNeeded()
                tableView.pin()
                // Measuring at the placement can change heights near it, which moves where the
                // placement lands; a couple of rounds settles it.
                for _ in 0..<3 {
                    guard measureRowsNearViewport() else { break }
                    tableView.pin()
                }
            }
            hasShownSnapshot = true
            syncSelection()
            didLayout()
        }

        func place(_ placement: FoldReading) {
            tableView.pinned = placement
            tableView.pin()
        }

        func scrollRowToVisible(_ row: Int) {
            guard row >= 0, row < rowCount else { return }
            let frame = tableView.rect(ofRow: row)
            let top = tableView.visibleTop
            let bottom = scrollView.contentView.bounds.maxY - scrollView.contentInsets.bottom
            if frame.minY < top {
                place(FoldReading(row: row, offset: 0))
            } else if frame.maxY > bottom {
                tableView.scroll(toClipY: frame.maxY - scrollView.contentView.bounds.height + scrollView.contentInsets.bottom)
                tableView.pinned = foldReading()
            }
        }

        func foldReading() -> FoldReading? {
            tableView?.foldReading()
        }

        func visibleRows() -> Range<Int>? {
            guard let tableView, let fold = foldReading() else { return nil }
            let visible = tableView.rows(in: tableView.visibleRect).asRange
            return fold.row..<max(visible.upperBound, fold.row + 1)
        }

        func reconfigureVisibleRows() {
            guard let tableView, hasShownSnapshot else { return }
            refresh(rows: IndexSet(integersIn: tableView.rows(in: tableView.visibleRect).asRange))
            measureRowsNearViewport()
        }

        func blank(rows: [Int]) {
            var changed = IndexSet()
            for row in rows where row < rowCount {
                guard tableView.view(atColumn: 0, row: row, makeIfNecessary: false) != nil else { continue }
                blankedRows[row] = tableView.rect(ofRow: row).height
                changed.insert(row)
            }
            guard !changed.isEmpty else { return }
            refresh(rows: changed)
        }
    }
}

/// A row: one SwiftUI view, sized by Auto Layout so the table can size the row to fit it.
final class HostingCell: NSTableCellView {

    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // The row's height is measured by the coordinator; the hosting view's own idea of its
        // size would only fight it.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Reports the reader's wheel and trackpad scrolling, which `NSScrollView` has no delegate for.
final class TimelineScrollView: NSScrollView {

    var onScrollWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
        super.scrollWheel(with: event)
    }
}

/// A table that keeps its fold where it was put. The same two corrections as
/// `TimelineCollectionView` on iOS — see there.
final class TimelineTableView: NSTableView {

    var pinned: FoldReading?

    var onLayout: (() -> Void)?

    var isReaderScrolling: () -> Bool = { false }

    private var isCorrecting = false

    override func tile() {
        let before = isReaderScrolling() ? foldScreenPosition() : nil
        super.tile()
        correct(from: before)
    }

    override func layout() {
        let before = isReaderScrolling() ? foldScreenPosition() : nil
        super.layout()
        correct(from: before)
        onLayout?()
    }

    func correct(from before: (row: Int, y: CGFloat)?) {
        guard !isCorrecting else { return }
        isCorrecting = true
        defer { isCorrecting = false }

        if let before {
            guard before.row < numberOfRows else { return }
            let drift = (rect(ofRow: before.row).minY - clipOriginY) - before.y
            if abs(drift) > 0.5 {
                scroll(toClipY: clipOriginY + drift)
            }
        } else if !isReaderScrolling() {
            pin()
        }
    }

    private var clipView: NSClipView? {
        enclosingScrollView?.contentView
    }

    private var clipOriginY: CGFloat {
        clipView?.bounds.minY ?? 0
    }

    private var insetTop: CGFloat {
        enclosingScrollView?.contentInsets.top ?? 0
    }

    /// The top of the viewport in table coordinates: under the toolbar, not behind it.
    var visibleTop: CGFloat {
        clipOriginY + insetTop
    }

    func foldReading() -> FoldReading? {
        guard numberOfRows > 0, let clipView, clipView.bounds.height > 0 else { return nil }
        let top = visibleTop
        var row = self.row(at: NSPoint(x: bounds.midX, y: top + 0.5))
        if row < 0 {
            row = rows(in: NSRect(x: 0, y: top, width: bounds.width, height: clipView.bounds.height)).location
        }
        guard row >= 0, row < numberOfRows else { return nil }
        // Never below the top edge, which only an elastic overscroll at the top produces.
        return FoldReading(row: row, offset: min(rect(ofRow: row).minY - top, 0))
    }

    func foldScreenPosition() -> (row: Int, y: CGFloat)? {
        guard let fold = foldReading() else { return nil }
        return (fold.row, rect(ofRow: fold.row).minY - clipOriginY)
    }

    func pin() {
        guard let pinned, pinned.row >= 0, pinned.row < numberOfRows, let clipView, clipView.bounds.height > 0 else {
            return
        }
        let target = rect(ofRow: pinned.row).minY - pinned.offset - insetTop
        if abs(clipOriginY - target) > 0.5 {
            scroll(toClipY: target)
        }
    }

    func scroll(toClipY y: CGFloat) {
        guard let clipView, let scrollView = enclosingScrollView else { return }
        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, frame.height - clipView.bounds.height + scrollView.contentInsets.bottom)
        let clamped = min(max(y, minY), maxY)
        guard abs(clipView.bounds.minY - clamped) > 0.5 else { return }
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private extension NSRange {
    var asRange: Range<Int> {
        guard location != NSNotFound else { return 0..<0 }
        return location..<(location + length)
    }
}
#endif
