import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// The reading pane.
///
/// Dispatches on item kind: articles render as HTML in a web view with reader styling, Mastodon
/// statuses render natively in SwiftUI. That split is deliberate — a status is small and
/// structured, and putting it behind a web view would lose native text selection, Dynamic Type and
/// the platform's own link handling for no benefit.
struct DetailView: View {

    @Binding var itemID: String?

    /// The scope the item was selected from, so "next" follows the list the reader is actually in
    /// rather than the whole store.
    let scope: ScopeID

    let moveFocus: (FocusedColumn) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL

    /// Everything saved for later, so the shortcut knows which way its toggle points.
    ///
    /// A whole query rather than a count fetched per item: the list is small — what a person puts
    /// aside, not what they subscribe to — and observing it means a save made from the timeline's
    /// swipe is already reflected here, with nothing having to notify anything.
    @Query private var readLaterEntries: [ReadLaterEntry]

    /// Neighbours, resolved when the item changes rather than per redraw.
    ///
    /// Two `fetchLimit: 1` queries, run once per item, so the arrows can be correctly disabled at
    /// the ends of the list instead of being offered and doing nothing.
    @State private var previousItemID: String?
    @State private var nextItemID: String?

    var body: some View {
        // Resolved exactly once per body evaluation, and handed to everything that needs it.
        //
        // `resolvedItem` is a fetch, and it used to be reached as a computed property from five
        // places in the toolbar and one more in the content — so opening an article ran six
        // `FetchDescriptor`s, and every redraw ran six more. The timeline had the identical
        // problem and fixed it the identical way; see `TimelineList.item(withID:)`.
        let selection = resolvedSelection

        return content(selection)
            .toolbar { itemActions(selection) }
            #if !os(macOS)
            .task(id: itemID) {
                previousItemID = neighbour(.newer)
                nextItemID = neighbour(.older)
            }
            .toolbar {
                // Buttons only. There was a swipe here as well, and no threshold made it behave:
                // set low it stole ordinary scrolling, set high enough not to it was undiscoverable
                // and still fired on a decisive flick. A reading pane's vertical drag belongs to
                // the text — the chevrons say what they do and cannot be triggered by accident.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Previous Item", systemImage: "chevron.up") {
                        move(.newer)
                    }
                    .disabled(previousItemID == nil)

                    Spacer()

                    Button("Next Item", systemImage: "chevron.down") {
                        move(.older)
                    }
                    .disabled(nextItemID == nil)
                }
            }
            #endif
    }

    /// Share, and nothing else.
    ///
    /// ## What used to be here, and why it is not
    ///
    /// Read Later and Open in Browser both had buttons in this group. Both are gone, and each for
    /// its own reason:
    ///
    /// - **Read Later** is reachable three other ways — a swipe on the row, the row's context menu,
    ///   and a configurable key — so the button was a fourth route to something already well
    ///   covered. On an iPhone toolbar that is a scarce slot spent on redundancy.
    /// - **Open in Browser** moved into the content: the article's own headline is now a link to
    ///   the original, which is where a reader already expects to be able to click through, and it
    ///   costs no toolbar at all. A post's timestamp does the same job — see `StatusCard`.
    ///
    /// Share stays, because there is nothing else in the app that does it and no natural place in
    /// the content to hang it from.
    ///
    /// The keys those two buttons carried are handled over the pane instead — see
    /// ``handleShortcut(_:selection:)``. A `keyboardShortcut` needs a button to live on, and the shortcuts
    /// are the reader's own configuration; losing them along with the buttons would be a different
    /// change from the one that was asked for.
    ///
    /// ## Why there is always an item here, even with nothing selected
    ///
    /// This group used to hold only the `if let`, so an empty reading pane contributed *no* toolbar
    /// content at all — and on macOS the whole window shares one strip. A split view's columns are
    /// kept apart in that strip by a separator tracking the divider, and a column with nothing to
    /// put in the toolbar does not get one: the timeline's Refresh and position menu, which sit at
    /// the right-hand edge of their own column, slid across to the right-hand edge of the *window*
    /// the moment the selection was cleared. Switching scope clears it (see `RootView`), so the
    /// buttons moved on every click in the sidebar.
    ///
    /// Holding the slot disabled rather than removing it is also what the platform does with
    /// everything else that acts on a selection — a menu item greys out, it does not disappear —
    /// and a toolbar whose buttons stay put is one you can aim at without looking.
    @ToolbarContentBuilder
    private func itemActions(_ selection: Selection?) -> some ToolbarContent {
        ToolbarItemGroup {
            if let url = selection?.url {
                ShareLink(item: url)
                    // Its own title comes from the system and is already localised; the tooltip is
                    // ours and so needs a string of its own.
                    .toolbarButtonHelp("Share")
            } else {
                // `ShareLink` needs something to share, so the placeholder cannot be one — it is a
                // button wearing the same name and the same glyph, and it is never enabled.
                Button("Share", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
                    .toolbarButtonHelp("Share")
            }
        }
    }

    /// Runs a configured shortcut over the reading pane, or declines the key.
    ///
    /// The counterpart to `TimelineList.handleShortcut(_:)`, which handles the same two keys while
    /// the *list* has focus. Both are needed: the shortcuts used to ride on toolbar buttons, which
    /// are gone, and a reader with focus in the reading pane is exactly the reader most likely to
    /// reach for "save this".
    ///
    /// Declining matters as much as handling — every keystroke over the pane arrives here, and
    /// swallowing the unbound ones would take away `Space` and everything else the pane does for
    /// itself.
    private func handleShortcut(_ press: KeyPress, selection: Selection?) -> KeyPress.Result {
        if settings.shortcuts.readLater.matches(press), selection != nil {
            toggleReadLater()
            return .handled
        }
        if settings.shortcuts.openInBrowser.matches(press), let url = selection?.url {
            // Behind the app where the platform allows it, matching the two lists — the key means
            // the same thing wherever focus happens to be. Clicking the article's headline is the
            // route that still goes to the browser. See `LinkActions.openForShortcut(_:otherwise:)`.
            LinkActions.openForShortcut(url, otherwise: openURL)
            return .handled
        }
        return .ignored
    }

    /// Saves the item, or removes the entry that is already there.
    ///
    /// Keyed on the **selected** id rather than on the resolved item's, and that distinction is
    /// load-bearing: `ItemResolution` may have answered with a local row whose id differs from the
    /// entry's, so toggling by the item's id would fail to find the entry and save a *second* copy
    /// of the same article instead of removing the first.
    private func toggleReadLater() {
        guard let itemID else { return }

        if readLaterEntries.contains(where: { $0.itemID == itemID }) {
            _ = try? ReadLaterService.remove(itemID: itemID, in: modelContext)
            // Without the tombstone the next pull from another device simply re-creates the entry
            // that was just removed.
            try? SyncOutbox.recordReadLaterDeletion(itemID: itemID, in: modelContext)
            try? modelContext.save()
            services.syncSoon()
            return
        }

        // Saving needs the cached item — a snapshot is taken *from* one, so there is nothing to
        // save when the only thing on screen is already a snapshot.
        guard let item = resolvedItem else { return }
        do {
            let feed = source(for: item)
            let result = try ReadLaterService.toggle(
                item,
                sourceTitle: feed?.title ?? "",
                sourceIconURLString: feed?.iconURLString,
                archiveContent: settings.reading.archivesReadLaterContent,
                in: modelContext
            )
            try SyncOutbox.record(result, in: modelContext)
            try modelContext.save()
            services.syncSoon()
        } catch {
            // A snapshot that fails to write is corrected by pressing the button again; there is
            // nothing here worth interrupting the reader for.
            return
        }
    }

    /// The item's feed, for the Read Later snapshot's name and icon.
    ///
    /// Fetched only when something is actually saved, not per redraw — a snapshot is taken once
    /// and has to stand on its own after the cache is pruned, so it cannot point at the source.
    private func source(for item: CachedItem) -> CachedSource? {
        let sourceID = item.sourceID
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func neighbour(_ direction: TimelineNavigator.Direction) -> String? {
        guard let itemID else { return nil }
        return try? TimelineNavigator.adjacentItemID(
            to: itemID,
            in: scope,
            direction: direction,
            context: modelContext
        )
    }

    @ViewBuilder
    private func content(_ selection: Selection?) -> some View {
        Group {
            switch selection {
            case .cached(let item):
                switch item.kind {
                case .article:
                    ArticleReaderView(item: item)
                case .status:
                    StatusReaderView(item: item)
                }
            case .saved(let entry):
                ArchivedItemView(entry: entry)
            case nil:
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "doc.text",
                    description: Text("Choose an item from the list.")
                )
            }
        }
        .onKeyPress(.leftArrow) {
            moveFocus(.timeline)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            handleShortcut(press, selection: selection)
        }
    }

    /// Moves the selection one item along, if there is one.
    ///
    /// Swiping up moves *down* the list, matching the direction the content moves under the
    /// finger — the same convention as a photo library or a card stack.
    private func move(_ direction: TimelineNavigator.Direction) {
        guard let next = neighbour(direction) else { return }
        itemID = next
    }

    /// What the pane is showing.
    ///
    /// Two cases because a selection can outlive its cached item: a Read Later entry is a snapshot
    /// that stays after the cache is pruned, and it arrives from other devices carrying an id this
    /// device never wrote. See ``ArchivedItemView``.
    private enum Selection {
        case cached(CachedItem)
        case saved(ReadLaterEntry)

        var url: URL? {
            switch self {
            case .cached(let item): item.url
            case .saved(let entry): entry.url
            }
        }
    }

    private var resolvedSelection: Selection? {
        if let item = resolvedItem { return .cached(item) }
        // Only reached when the cache has no such row, so the common path is unaffected: a saved
        // item that is still cached renders as the cached item, with its full body and its own
        // full-page toggle.
        guard let itemID,
              let entry = try? ReadLaterService.entry(for: itemID, in: modelContext)
        else {
            return nil
        }
        return .saved(entry)
    }

    /// The cached row for the selection, if this device has one.
    ///
    /// Through `ItemResolution` rather than a bare `id ==` fetch, so an item saved on another
    /// device resolves to the local copy of the same article — which is what makes the reading
    /// pane, the Read Later toggle and the full-page setting all act on one row rather than
    /// treating the two ids as two different articles.
    private var resolvedItem: CachedItem? {
        guard let itemID else { return nil }
        return try? ItemResolution.cachedItem(for: itemID, in: modelContext)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var itemID: String?

    DetailView(itemID: $itemID, scope: .all, moveFocus: { _ in })
        .modelContainer(FixtureData.previewContainer())
}
#endif
