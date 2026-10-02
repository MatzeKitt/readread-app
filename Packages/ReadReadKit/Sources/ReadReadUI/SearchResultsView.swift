import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// A search over the selected scope, standing in for its timeline while a query is typed.
///
/// ## Why this replaces the timeline rather than filtering it
///
/// The timeline *is* the reading position: whichever row sits at the top edge is written down as
/// where the reader is, and synced. Narrowing that list to the matches would put some old result at
/// the top edge, and the fold would faithfully record it — a search for last month's article would
/// move the position a month back, on every device, with no read/unread state to recover from.
///
/// So a search is a list of its own, with no fold, no restore and no position, exactly like
/// Filtered Items. Clearing the field brings the timeline back as a fresh view, which restores
/// itself to the position it had — the same thing a change of scope does.
///
/// Queries only; owns no selection. The split from ``SearchResultsList`` is the one
/// `TimelineQueryHost` documents: a `@Query` re-fetches whenever the view holding it re-evaluates,
/// and the view reading the selection re-evaluates on every arrow key.
struct SearchResultsView: View {

    @Binding var selectedItemID: String?
    let moveFocus: (FocusedColumn) -> Void

    @Query private var items: [CachedItem]
    @Query private var sources: [CachedSource]
    @Query private var readLaterEntries: [ReadLaterEntry]
    @Query private var accounts: [AccountRecord]

    init(
        scope: ScopeID,
        query: SearchQuery,
        selectedItemID: Binding<String?>,
        moveFocus: @escaping (FocusedColumn) -> Void
    ) {
        _selectedItemID = selectedItemID
        self.moveFocus = moveFocus
        // In the timeline's own order, so a result sits where the reader would expect it relative
        // to the others, and so next and previous in the reading pane agree with the list.
        _items = Query(
            filter: ScopeQuery.searchPredicate(for: scope, matching: query),
            sort: \CachedItem.sortKeyRaw,
            order: .reverse
        )
    }

    var body: some View {
        SearchResultsList(
            selectedItemID: $selectedItemID,
            moveFocus: moveFocus,
            items: items,
            sources: sources,
            readLaterEntries: readLaterEntries,
            accounts: accounts
        )
    }
}

private struct SearchResultsList: View {

    @Binding var selectedItemID: String?
    let moveFocus: (FocusedColumn) -> Void

    let items: [CachedItem]
    let sources: [CachedSource]
    let readLaterEntries: [ReadLaterEntry]
    let accounts: [AccountRecord]

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsModel.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Built once per body rather than per row. Unlike the timeline, this list has no fold
        // re-evaluating it while it scrolls, so there is nothing to gain from caching them in state.
        let titles = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let icons = Dictionary(
            sources.compactMap { source in source.iconURLString.map { (source.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let savedItemIDs = Set(readLaterEntries.map(\.itemID))

        List(selection: $selectedItemID) {
            ForEach(items) { item in
                let isSaved = savedItemIDs.contains(item.id)

                ItemRow(
                    item: item,
                    sourceTitle: titles[item.sourceID],
                    sourceIconURLString: icons[item.sourceID],
                    showsLateArrival: settings.reading.showsLateArrivalBadges,
                    headingScale: settings.reading.listHeadingScale,
                    bodyScale: settings.reading.listBodyScale,
                    lineHeight: settings.reading.contentLineHeight
                )
                    // The same marking as the timeline. See `SelectionMarker`.
                    .listRowBackground(SelectionMarker(isSelected: selectedItemID == item.id))
                    // Swiping right is "toggle Read Later" everywhere in the app.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(
                            isSaved ? "Remove from Read Later" : "Read Later",
                            systemImage: isSaved ? "bookmark.slash" : "bookmark"
                        ) {
                            toggleReadLater(item, titles: titles, icons: icons)
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        ItemActionsMenu(
                            item: item,
                            accounts: accounts,
                            isSaved: isSaved,
                            toggleReadLater: { toggleReadLater(item, titles: titles, icons: icons) }
                        )
                    }
            }
        }
        .plainListSelection()
        .overlay {
            if items.isEmpty {
                ContentUnavailableView.search
            }
        }
        // The whole of this list's toolbar, as every list here declares its own — see the note in
        // `TimelineView.body`. No position menu: a search has no position to show or return to.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarButton()
            }
        }
        // The same keyboard behaviour as the timeline it stands in for: a click focuses the
        // column, the arrows hand focus across, and the configured keys work over a result.
        .activatesColumn(.timeline, onSelecting: selectedItemID, moveFocus: moveFocus)
        .onKeyPress(.leftArrow) {
            moveFocus(.sidebar)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocus(.detail)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            handleShortcut(press, titles: titles, icons: icons)
        }
    }

    /// The timeline's shortcuts, over a result. Declines everything else so the list keeps its
    /// own keys — see `TimelineList.handleShortcut(_:)`.
    private func handleShortcut(
        _ press: KeyPress,
        titles: [String: String],
        icons: [String: String]
    ) -> KeyPress.Result {
        guard let item = selectedItem else { return .ignored }

        if settings.shortcuts.readLater.matches(press) {
            toggleReadLater(item, titles: titles, icons: icons)
            return .handled
        }
        if settings.shortcuts.openInBrowser.matches(press), let url = item.url {
            LinkActions.openForShortcut(url, otherwise: openURL)
            return .handled
        }
        return .ignored
    }

    /// Through its unique index rather than a scan of the results. See `TimelineList.item(withID:)`.
    private var selectedItem: CachedItem? {
        guard let id = selectedItemID else { return nil }
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// The timeline's toggle: snapshot or remove, queue it for sync, save.
    private func toggleReadLater(
        _ item: CachedItem,
        titles: [String: String],
        icons: [String: String]
    ) {
        do {
            let result = try ReadLaterService.toggle(
                item,
                sourceTitle: titles[item.sourceID] ?? "",
                sourceIconURLString: icons[item.sourceID],
                archiveContent: settings.reading.archivesReadLaterContent,
                in: modelContext
            )
            try SyncOutbox.record(result, in: modelContext)
            try modelContext.save()
        } catch {
            return
        }
        services.syncSoon()
    }
}
