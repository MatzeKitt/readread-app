import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The window subtitle, which follows the fold.
///
/// Its own view so that reading the fold takes a dependency *here* rather than in the list: the
/// fold moves with every row that crosses the top edge. Held as a background of the list, which
/// keeps it in the hierarchy — `navigationSubtitle` travels up as a preference, so it does not
/// matter that this draws nothing.
private struct TimelineSubtitle: View {

    let controller: TimelineController
    let counts: ThresholdCounts

    var body: some View {
        Color.clear
            // Both platforms: iPhone otherwise has no count anywhere except the sidebar it has
            // already navigated away from.
            .navigationSubtitle(subtitle)
    }

    private var subtitle: Text {
        let count = controller.foldRow ?? counts.newerCount(for: controller.scope)

        if case .lateArrivals = controller.scope {
            // Not "newer": these arrived below the position of the scope they landed in, and
            // calling them newer is the exact confusion the separate list exists to avoid.
            return count == 0
                ? Text("Nothing waiting")
                : Text("^[\(count) item](inflect: true) arrived")
        }
        return count == 0 ? Text("Up to date") : Text("\(count) newer")
    }
}

/// Tells the controller when the reader comes back to the app, so it can move to where another
/// device left off.
///
/// Keyed on `AppServices.positionMergeGeneration`, which steps each time the app is activated
/// after being away and a new merge of positions begins. Its own view so that observing
/// `AppServices` does not take a dependency in the list's body.
private struct TimelineActivationTrigger: View {

    let controller: TimelineController

    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onChange(of: services.positionMergeGeneration) {
                controller.activated()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                controller.setAppActive(phase == .active)
            }
    }
}

/// The "N newer" button's face.
///
/// Split out for the same reason as ``TimelineSubtitle``: the count moves with every row that
/// crosses the fold.
private struct TimelineCountLabel: View {

    let controller: TimelineController
    let counts: ThresholdCounts

    var body: some View {
        let newer = controller.foldRow ?? counts.newerCount(for: controller.scope)
        if newer == 0 {
            Label("Up to date", systemImage: "checkmark.circle")
        } else {
            // Built out rather than `Label(_:systemImage:)`, so the glyph can take the accent
            // colour on its own and leave the count set in the toolbar's own.
            Label {
                Text("\(newer) newer")
            } icon: {
                Image(systemName: "bell.badge")
            }
        }
    }
}

/// Refresh, as its own view rather than inline in the timeline's toolbar.
///
/// Not tidiness. It reads `isRefreshing`, which changes at the start and end of every refresh, and
/// an `@Observable` read inside `TimelineView.body` would take that dependency for the *routing*
/// view — whose child owns the timeline's `@Query`, and re-evaluating that re-runs a fetch over
/// the whole scope. Reading it one level down confines the update to the button that is changing,
/// which is the same reason `SidebarRowView` and `TimelineCountLabel` exist.
struct RefreshToolbarButton: View {

    @Environment(AppServices.self) private var services

    var body: some View {
        // A spinner in place of the button, rather than an effect on it, on both platforms.
        //
        // On iOS it is the only thing that works: a symbol effect does not survive the trip to a
        // `UIBarButtonItem`, because what crosses is the label's *image*, not the view it was
        // attached to. The same reason a `ProgressView` in the label's icon slot showed nothing —
        // there was no image in it to take. As the item's own content SwiftUI has to host a real
        // view, and the indicator renders.
        //
        // On the Mac a turning arrow did work, and was still the wrong picture. An indeterminate
        // spinner is what every other Mac app puts in a toolbar while it is fetching, and the two
        // platforms saying the same thing in the same shape is worth more than the Mac having its
        // own flourish.
        //
        // Deliberately *not* gated on Reduce Motion, which the Mac's spin was. A spinner is not
        // decoration dressing up a disabled button — while it is up it is the only thing on screen
        // saying the app is working, and a progress indicator is the platform's own idiom for
        // exactly that, on both platforms, whatever the motion setting says.
        #if os(macOS)
        // Laid over the button rather than swapped in for it, which is what the Mac did too until
        // the whole strip flickered at the start and end of every refresh. A different view in the
        // same `ToolbarItem` is a different `NSToolbarItem` to SwiftUI: it removed the item and
        // inserted a new one under a fresh identifier each time, and the toolbar re-laid every
        // platter around it. With the button always there and only hidden, the item, its view and
        // its platter all stay put, and the spinner is the one thing that changes. On the Mac the
        // button is hosted as a real view, so the overlay renders. iOS keeps the swap below: a
        // bare button there becomes a `UIBarButtonItem`, which takes its image and nothing laid
        // over it.
        //
        // The button keeps its footprint while hidden, so the padding the swap needs is not
        // needed here. Disabled, so ⌘R does not start a second run behind the spinner.
        button
            .opacity(services.isRefreshing ? 0 : 1)
            .disabled(services.isRefreshing)
            .overlay {
                if services.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing")
                }
            }
        #else
        // Swapping the whole item changes its identity, so it crossfades rather than morphing.
        // That is the intended reading here: the button is gone for as long as the work runs.
        if services.isRefreshing {
            ProgressView()
                .controlSize(.small)
                // A bare indicator is the spinner alone, where the button it replaces is a glyph
                // *plus* the button's own insets. Dropped into the same toolbar item that reads as
                // a smaller control that has shrunk, and the strip shifts around it as it comes and
                // goes. The padding buys back roughly what the button's chrome was contributing, so
                // the item keeps its footprint for the length of the run.
                .padding(10)
                .accessibilityLabel("Refreshing")
        } else {
            button
        }
        #endif
    }

    private var button: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await services.refreshNow() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .toolbarButtonHelp("Refresh")
    }
}

/// The item list for the selected scope.
///
/// Ordered newest-published first, which is the ordering the whole threshold design is built
/// around: recently-fetched old content stays where it belongs chronologically rather than
/// floating to the top.
struct TimelineView: View {

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts

    /// What is in the search field, as typed.
    @Binding var searchText: String

    /// The search that is actually run: ``searchText`` once typing pauses, or nil with nothing to
    /// search for. Settled by `RootView`, which also hands it to the reading pane.
    let searchQuery: SearchQuery?

    /// Called to hand keyboard focus to another column.
    let moveFocus: (FocusedColumn) -> Void

    @Environment(\.modelContext) private var modelContext

    /// Whether the search field has the keyboard, so ⌘F can give it the keyboard.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if case .readLater = scope {
                // Read Later renders from `ReadLaterEntry`, not `CachedItem`, because entries are
                // self-contained snapshots that outlive cache pruning.
                //
                // Keyed on the query, because the list's `@Query` is built in its initialiser and a
                // new predicate is not a new view. The same holds for the two lists below.
                ReadLaterListView(
                    selectedItemID: $selectedItemID,
                    searchQuery: searchQuery,
                    moveFocus: moveFocus
                )
                .id(searchQuery)
            } else if case .filtered = scope {
                // Its own view rather than the timeline with an inverted predicate: every row says
                // *which* rule hid it, which is the only question the list exists to answer, and
                // there is no reading position to restore or report here.
                FilteredItemsView(
                    selectedItemID: $selectedItemID,
                    searchQuery: searchQuery,
                    moveFocus: moveFocus
                )
                .id(searchQuery)
            } else if let searchQuery {
                // In place of the timeline, never narrowing it: the timeline's top row is the
                // reading position, and a narrowed list would write an old result down as where the
                // reader is. See `SearchResultsView`. Leaving this branch brings the timeline back
                // as a new view, which restores its position like any change of scope.
                SearchResultsView(
                    scope: scope,
                    query: searchQuery,
                    selectedItemID: $selectedItemID,
                    moveFocus: moveFocus
                )
                .id(searchQuery)
            } else {
                TimelineQueryHost(
                    scope: scope,
                    selectedItemID: $selectedItemID,
                    counts: counts,
                    moveFocus: moveFocus
                )
                // One list per scope, and this one modifier is what makes that true.
                //
                // Without it every timeline scope — All Items, a folder, a feed, Older Items —
                // is the *same* branch of the `Group` above, so SwiftUI matched them by position
                // and type and handed the new scope the old scope's view: its `@State`, its fold,
                // its `hasRestored`, and the table's own scroll offset. Read Later and Filtered
                // Items were unaffected, being branches of their own, which is why this looked
                // like it worked.
                //
                // What that cost: switching scope kept the previous scope's scroll offset and fold,
                // and the fold was then written down as the *new* scope's reading position.
                //
                // It also gives every scope its own `TimelineController`, which is what positions
                // are tracked by.
                .id(scope)
            }
        }
        .navigationTitle(scopeTitle)
        // Here, on the column's root, unlike the toolbars below: the field has to outlive the
        // branch it chooses between, or typing the first letter would swap the list out from under
        // the field being typed into. It searches whatever the sidebar has selected.
        .searchable(text: $searchText)
        .searchFocused($isSearchFocused)
        // ⌘F, which a `searchable` field does not answer to on its own: checked on macOS 26 against
        // a split view like this one, where the key left focus on the list and the typing that
        // followed went nowhere. The standard Edit ▸ Find item is still in the menu and does not
        // take the key from this — it only acts on text the focused view can search, and the list
        // is not one. Hidden, because the field is already on screen to be clicked; the key is the
        // only thing this adds.
        .background {
            Button("Search") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        // No `.toolbar` here, and that is the fix for a real bug rather than a tidying.
        //
        // Refresh used to be declared on this view — the column's root — so that one declaration
        // would serve all three lists below. It worked for the timeline and put the button in the
        // *reading pane's* end of the merged strip for Read Later, Older Items and Filtered Items:
        // the one action that belongs to the list, as far from the list as the window allows.
        //
        // The difference between the cases is this `Group`. Its branch changes identity when the
        // scope changes, and a toolbar attached above a branch that comes and goes is one SwiftUI
        // has to re-home; the lists that declared a toolbar of their own anchored theirs and this
        // one drifted. So every list now declares the whole of its own toolbar, Refresh included,
        // and none of them is nested under a second declaration that outlives them.
    }

    private var scopeTitle: String {
        switch scope {
        case .all: String(localized: "All Items")
        case .readLater: String(localized: "Read Later")
        case .lateArrivals: String(localized: "Older Items")
        case .filtered: String(localized: "Filtered Items")
        case .folder(let name): name
        case .mastodonHome: String(localized: "Home")
        case .source(let id): sourceTitle(for: id) ?? String(localized: "Feed")
        case .replySubscription(let id):
            (try? ReplySubscription.find(id, in: modelContext))?.title ?? String(localized: "Replies")
        }
    }

    private func sourceTitle(for sourceID: String) -> String? {
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first?.title
    }
}

/// Holds the small queries the rows draw from; owns no selection.
///
/// The items themselves are not queried here. The rows are a frozen snapshot that
/// ``TimelineController`` replaces only when the reader is not scrolling — a live `@Query` is
/// exactly what used to move the list under the reader's finger. These four are a handful of rows
/// each, and change when the reader does something rather than while they scroll.
private struct TimelineQueryHost: View {

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    let moveFocus: (FocusedColumn) -> Void

    /// Source titles for the row header line, resolved once for the whole list.
    @Query private var sources: [CachedSource]

    /// Everything currently saved for later, reduced to a set of ids rather than asked per row.
    @Query private var readLaterEntries: [ReadLaterEntry]

    /// The accounts, for the Like and Boost menu.
    @Query private var accounts: [AccountRecord]

    /// The reply subscriptions, so a followed reply's row can name the conversation it is in.
    @Query private var replySubscriptions: [ReplySubscription]

    init(
        scope: ScopeID,
        selectedItemID: Binding<String?>,
        counts: ThresholdCounts,
        moveFocus: @escaping (FocusedColumn) -> Void
    ) {
        self.scope = scope
        _selectedItemID = selectedItemID
        self.counts = counts
        self.moveFocus = moveFocus
    }

    var body: some View {
        TimelineList(
            scope: scope,
            selectedItemID: $selectedItemID,
            counts: counts,
            moveFocus: moveFocus,
            sources: sources,
            readLaterEntries: readLaterEntries,
            accounts: accounts,
            replySubscriptions: replySubscriptions
        )
    }
}

/// Creates the scope's controller once the environment it needs is available, then shows the list.
private struct TimelineList: View {

    let scope: ScopeID
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    let moveFocus: (FocusedColumn) -> Void
    let sources: [CachedSource]
    let readLaterEntries: [ReadLaterEntry]
    let accounts: [AccountRecord]
    let replySubscriptions: [ReplySubscription]

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    /// One per list, and the list is one per scope — see the `.id(scope)` in ``TimelineView``.
    @State private var controller: TimelineController?

    var body: some View {
        if let controller {
            TimelineContent(
                controller: controller,
                selectedItemID: $selectedItemID,
                counts: counts,
                moveFocus: moveFocus,
                sources: sources,
                readLaterEntries: readLaterEntries,
                accounts: accounts,
                replySubscriptions: replySubscriptions
            )
        } else {
            Color.clear.onAppear {
                let controller = TimelineController(
                    scope: scope,
                    services: services,
                    context: modelContext,
                    counts: counts
                )
                #if os(macOS)
                // Selects the fold item once the scope is placed, so the arrow keys start from
                // where reading left off rather than from the newest row. macOS only: on iPhone a
                // selection is a *pushed screen*, and opening a scope would land the reader inside
                // an article they never tapped.
                controller.didRestore = { [selection = $selectedItemID] itemID in
                    if selection.wrappedValue == nil {
                        selection.wrappedValue = itemID
                    }
                }
                #endif
                self.controller = controller
            }
        }
    }
}

private struct TimelineContent: View {

    let controller: TimelineController
    @Binding var selectedItemID: String?
    let counts: ThresholdCounts
    let moveFocus: (FocusedColumn) -> Void
    let sources: [CachedSource]
    let readLaterEntries: [ReadLaterEntry]
    let accounts: [AccountRecord]
    let replySubscriptions: [ReplySubscription]

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsModel.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL

    /// Derived from the small queries, and rebuilt only when they change, rather than on every
    /// body evaluation.
    @State private var sourceTitles: [String: String] = [:]
    @State private var sourceIcons: [String: String] = [:]
    @State private var savedItemIDs: Set<String> = []
    @State private var replySubscriptionTitles: [UUID: String] = [:]

    private var scope: ScopeID { controller.scope }

    private var isLateArrivalList: Bool {
        if case .lateArrivals = scope { return true }
        return false
    }

    var body: some View {
        list
            .overlay {
                if controller.hasLoaded, controller.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "tray",
                        description: Text("Items appear here once this source has been refreshed.")
                    )
                }
            }
            .toolbar {
                // Refresh belongs to the list it refills, so it is declared with the list.
                ToolbarItem(placement: .primaryAction) {
                    RefreshToolbarButton()
                }

                ToolbarItem(placement: .primaryAction) {
                    if isLateArrivalList {
                        // No reading position to show: this list is emptied by dismissing, not by
                        // a marker moving through it.
                        Button("Dismiss All", systemImage: "checkmark.circle") {
                            dismissAllLateArrivals()
                        }
                        .disabled(controller.isEmpty)
                        .toolbarButtonHelp("Dismiss All")
                    } else {
                        positionMenu
                    }
                }
            }
            // Clicking a row selects it and does not move SwiftUI's focus, which would leave the
            // keyboard dead over the list it had just been used on. See `activatesColumn`.
            .activatesColumn(.timeline, onSelecting: selectedItemID, moveFocus: moveFocus)
            .onKeyPress(.leftArrow) {
                moveFocus(.sidebar)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                moveFocus(.detail)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
            }
            // The configurable shortcuts, handled here as well as on the buttons that own them:
            // a bare letter does not reliably reach a toolbar shortcut from here.
            .onKeyPress(phases: .down) { press in
                handleShortcut(press)
            }
            .background {
                TimelineSubtitle(controller: controller, counts: counts)
                TimelineActivationTrigger(controller: controller)
            }
            .task(id: sources.count) {
                sourceTitles = Self.titles(of: sources)
                sourceIcons = Self.icons(of: sources)
            }
            .task(id: readLaterEntries.count) {
                savedItemIDs = Set(readLaterEntries.map(\.itemID))
            }
            // Keyed on the titles as well as the ids: renaming a subscription is the main thing
            // the reader does to one, and the rows should follow.
            .task(id: replySubscriptions.map { "\($0.id)|\($0.title)" }) {
                replySubscriptionTitles = Dictionary(
                    replySubscriptions.map { ($0.id, $0.title) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            .onAppear {
                // Back from a pushed article on iPhone: the badge follows this list again.
                if let row = controller.foldRow { counts.reportLiveCount(row, for: scope) }
            }
            .onDisappear {
                // Leaving the list — which on iPhone is what opening an item does — is the same
                // kind of event as leaving the app: what the reader settled on is final.
                controller.flush()
                counts.clearLiveCount(for: scope)
            }
            // Delivered synchronously on the main thread by the poster, which is what makes this
            // usable at termination: the write and its `save()` complete before the app exits.
            .onReceive(NotificationCenter.default.publisher(for: Self.leavingForegroundNotification)) { _ in
                controller.flush()
            }
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        TimelineTable(
            controller: controller,
            selectedItemID: $selectedItemID,
            contentVersion: contentVersion,
            rowContent: rowView
        )
        // Focusable as a whole, so the keyboard is handled by the `onKeyPress` handlers above
        // rather than by the table, which never becomes first responder.
        .focusable()
        .focusEffectDisabled()
        #else
        TimelineCollection(
            controller: controller,
            selectedItemID: $selectedItemID,
            contentVersion: contentVersion,
            rowContent: rowView
        )
        .ignoresSafeArea(.container, edges: .vertical)
        #endif
    }

    // MARK: - Rows

    /// Everything the rows draw from apart from the item, so the rows on screen are redrawn when it
    /// changes — and only then.
    private var contentVersion: Int {
        var hasher = Hasher()
        hasher.combine(settings.reading.listHeadingScale)
        hasher.combine(settings.reading.listBodyScale)
        hasher.combine(settings.reading.contentLineHeight)
        hasher.combine(settings.reading.showsLateArrivalBadges)
        hasher.combine(savedItemIDs)
        hasher.combine(sourceTitles)
        hasher.combine(sourceIcons)
        hasher.combine(replySubscriptionTitles)
        hasher.combine(accounts.map(\.persistentModelID))
        return hasher.finalize()
    }

    private func rowView(_ item: CachedItem, isSelected: Bool) -> AnyView {
        let isSaved = savedItemIDs.contains(item.id)
        return AnyView(
            ItemRow(
                item: item,
                sourceTitle: sourceTitles[item.sourceID],
                sourceIconURLString: sourceIcons[item.sourceID],
                replySubscriptionTitle: item.replySubscriptionID.flatMap { replySubscriptionTitles[$0] },
                // Every row in Older Items shares that state, so the badge would be noise rather
                // than the explanation it is in a mixed timeline.
                showsLateArrival: !isLateArrivalList && settings.reading.showsLateArrivalBadges,
                headingScale: settings.reading.listHeadingScale,
                bodyScale: settings.reading.listBodyScale,
                lineHeight: settings.reading.contentLineHeight
            )
            #if os(macOS)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            // Grey where a list would fill in the accent colour, with the accent spent on an
            // outline instead. See `SelectionMarker`. On iOS the cell draws it, behind its whole
            // width rather than inside its margins.
            .background(SelectionMarker(isSelected: isSelected))
            // The inset a list gives its rows, so the marker sits clear of the column's edges. The
            // table is plain so that rows are measured at its full width; see `TimelineTable`.
            .padding(.horizontal, 10)
            #endif
            .contentShape(Rectangle())
            // Leading edge, so the gesture is a swipe to the *right*, and `allowsFullSwipe` so a
            // decisive swipe saves without waiting for the button to be tapped.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button(
                    isSaved ? "Remove from Read Later" : "Read Later",
                    systemImage: isSaved ? "bookmark.slash" : "bookmark"
                ) {
                    toggleReadLater(item)
                }
                .tint(.orange)
            }
            .contextMenu {
                // Shared with the search results, which show the same rows in the same column.
                ItemActionsMenu(
                    item: item,
                    accounts: accounts,
                    isSaved: isSaved,
                    toggleReadLater: { toggleReadLater(item) }
                )

                if isLateArrivalList {
                    Divider()
                    Button("Dismiss", systemImage: "checkmark") {
                        item.arrivedLate = false
                        save()
                    }
                }
            }
        )
    }

    private static func titles(of sources: [CachedSource]) -> [String: String] {
        Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Feed id to favicon URL, for the rows. Feeds without one are left out rather than stored as
    /// `nil`, so the lookup answers the row's actual question.
    private static func icons(of sources: [CachedSource]) -> [String: String] {
        Dictionary(
            sources.compactMap { source in source.iconURLString.map { (source.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - The "N newer" menu

    private var positionMenu: some View {
        Menu {
            Button("Scroll to Timeline Position", systemImage: "arrow.down.to.line") {
                controller.returnToStoredPosition()
            }

            Button("Scroll to Top", systemImage: "arrow.up.to.line") {
                controller.jump(to: 0)
            }

            Button("Scroll Selection to Top", systemImage: "text.insert") {
                guard let row = controller.row(of: selectedItemID) else { return }
                controller.jump(to: row)
            }
            .disabled(selectedItemID == nil)
        } label: {
            TimelineCountLabel(controller: controller, counts: counts)
        }
        // A count is the point of the button, so it must not be reduced to an icon.
        .labelStyle(.titleAndIcon)
        .help("Reading position")
    }

    // MARK: - Keyboard

    /// Moves the selection one row up or down and brings it into view, like a list's own arrow
    /// keys. With nothing selected it starts from the fold.
    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let count = controller.snapshot.count
        guard count > 0 else { return .ignored }
        let start = controller.row(of: selectedItemID) ?? controller.foldRow.map { $0 - delta } ?? -delta
        let row = min(max(start + delta, 0), count - 1)
        guard let itemID = controller.itemID(at: row) else { return .ignored }
        selectedItemID = itemID
        controller.reveal(row: row)
        return .handled
    }

    /// Runs a configured shortcut, or declines the key so the list keeps its own behaviour.
    private func handleShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard let row = controller.row(of: selectedItemID), let item = controller.item(at: row) else {
            return .ignored
        }

        if settings.shortcuts.readLater.matches(press) {
            toggleReadLater(item)
            return .handled
        }
        if settings.shortcuts.openInBrowser.matches(press), let url = item.url {
            // Behind the app where the platform allows it — working down a list is the case this
            // key exists for. See `LinkActions.openForShortcut(_:otherwise:)`.
            LinkActions.openForShortcut(url, otherwise: openURL)
            return .handled
        }
        return .ignored
    }

    // MARK: - Actions

    /// Saves the item for later, or removes it if it is already saved.
    ///
    /// The snapshot is taken here rather than when the list is next opened, because by then the
    /// cached item may have been pruned.
    private func toggleReadLater(_ item: CachedItem) {
        do {
            let result = try ReadLaterService.toggle(
                item,
                sourceTitle: sourceTitles[item.sourceID] ?? "",
                sourceIconURLString: sourceIcons[item.sourceID],
                archiveContent: settings.reading.archivesReadLaterContent,
                in: modelContext
            )
            try SyncOutbox.record(result, in: modelContext)
        } catch {
            return
        }
        services.syncSoon()
        save()
    }

    /// Clears the flag on everything in the list, emptying it.
    private func dismissAllLateArrivals() {
        _ = try? ThresholdService.clearLateArrivals(for: scope, in: modelContext)
        save()
    }

    private static var leavingForegroundNotification: Notification.Name {
        #if os(macOS)
        AppServices.willQuitNotification
        #else
        UIApplication.didEnterBackgroundNotification
        #endif
    }

    /// Persists and refreshes the counts, which observe `ModelContext.didSave`.
    private func save() {
        try? modelContext.save()
    }
}
