import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// The Read Later list.
///
/// Reads `ReadLaterEntry` rather than `CachedItem`. Entries are self-contained snapshots taken when
/// an item is saved, so the list keeps working after the cache prunes the original — which is the
/// whole point of saving something for later.
struct ReadLaterListView: View {

    @Binding var selectedItemID: String?
    let moveFocus: (FocusedColumn) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL

    /// Most recently saved first, which is the order people expect from a save-for-later pile.
    @Query(sort: \ReadLaterEntry.addedAt, order: .reverse) private var entries: [ReadLaterEntry]

    @Query private var sources: [CachedSource]

    /// Feed id to favicon, for entries saved before the icon was part of the snapshot.
    ///
    /// The entry's own icon wins where it has one — that is the durable copy, and the whole point
    /// of a snapshot is that it still works once the feed is gone. This only fills the gap left by
    /// every article saved up to now, all of which have none: an item carries no icon of its own.
    private var sourceIcons: [String: String] {
        Dictionary(
            sources.compactMap { source in source.iconURLString.map { (source.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        let icons = sourceIcons

        return List(selection: $selectedItemID) {
            ForEach(entries) { entry in
                ReadLaterRow(
                    entry: entry,
                    sourceIconURLString: icons[entry.sourceID],
                    headingScale: settings.reading.listHeadingScale,
                    bodyScale: settings.reading.listBodyScale,
                    lineHeight: settings.reading.contentLineHeight
                )
                    .tag(entry.itemID)
                    // The same marking as the timeline, for the same reason. See `SelectionMarker`.
                    .listRowBackground(SelectionMarker(isSelected: selectedItemID == entry.itemID))
                    .contextMenu {
                        Button("Remove from Read Later", systemImage: "bookmark.slash") {
                            remove(entry.itemID)
                        }
                        if let url = entry.url {
                            Divider()
                            Link("Open in Browser", destination: url)
                            // The same pair as the timeline's menu. The two lists share a column
                            // and a reader moves between them, so an action offered on one row and
                            // missing from the other reads as a bug rather than as a decision.
                            Button("Copy Link", systemImage: "link") {
                                LinkActions.copy(url)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "bookmark.slash", role: .destructive) {
                            remove(entry.itemID)
                        }
                    }
                    // Swiping right is "toggle Read Later" everywhere in the app; here the item is
                    // already saved, so the toggle is a removal.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button("Remove", systemImage: "bookmark.slash") {
                            remove(entry.itemID)
                        }
                        .tint(.orange)
                    }
            }
        }
        .plainListSelection()
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing Saved",
                    systemImage: "bookmark",
                    description: Text("Items you mark for later appear here.")
                )
            }
        }
        // The whole of this column's toolbar, Refresh included. Declaring only the list's own
        // buttons here and leaving Refresh to the routing view above is what put Refresh at the
        // reading pane's end of the strip — see the note in `TimelineView.body`.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarButton()
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Remove from Read Later", systemImage: "bookmark.slash") {
                    guard let selectedItemID else { return }
                    remove(selectedItemID)
                }
                .disabled(selectedEntry == nil)
                .keyboardShortcut(settings.shortcuts.readLater)
                .toolbarButtonHelp("Remove from Read Later")
            }

            // Open in Browser is deliberately absent, and it is the same decision the reading
            // pane already made — see `DetailView.itemActions`. A saved item's headline is a link
            // to the original, which is where a reader looks to click through anyway, so the
            // button was a second route to something the content already offers. The configured
            // key still works: `onKeyPress` below handles it over the list.
        }
        .onKeyPress(.leftArrow) {
            moveFocus(.sidebar)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocus(.detail)
            return .handled
        }
        // The key Open in Browser used to carry, now that the button is gone. A `keyboardShortcut`
        // needs a button to live on, and the shortcut is the reader's own configuration — losing
        // it along with the button would be a second change nobody asked for. The same move
        // `DetailView.handleShortcut(_:selection:)` makes for the same two keys.
        //
        // Declining the rest matters as much as handling this one: every keystroke over the list
        // arrives here, and swallowing the unbound ones would take away the list's own navigation.
        .onKeyPress(phases: .down) { press in
            guard settings.shortcuts.openInBrowser.matches(press), let url = selectedEntry?.url else {
                return .ignored
            }
            // Behind the app where it can be, as in the timeline — a saved pile is worked through
            // the same way. See `LinkActions.openForShortcut(_:otherwise:)`.
            LinkActions.openForShortcut(url, otherwise: openURL)
            return .handled
        }
    }

    private var selectedEntry: ReadLaterEntry? {
        selectedItemID.flatMap { id in entries.first { $0.itemID == id } }
    }

    /// Removes an entry and queues its tombstone.
    ///
    /// The tombstone is what stops the entry reappearing: without it, the next pull from another
    /// device would simply re-create the row that was just deleted.
    private func remove(_ itemID: String) {
        if selectedItemID == itemID {
            // Otherwise the detail column keeps rendering an entry that no longer exists.
            selectedItemID = nil
        }
        _ = try? ReadLaterService.remove(itemID: itemID, in: modelContext)
        try? SyncOutbox.recordReadLaterDeletion(itemID: itemID, in: modelContext)
        try? modelContext.save()
        services.syncSoon()
    }
}

struct ReadLaterRow: View {

    let entry: ReadLaterEntry

    /// The feed's favicon, used only when the snapshot has none of its own.
    var sourceIconURLString: String?

    var headingScale: TextScale = .standard
    var bodyScale: TextScale = .standard

    /// Leading for the excerpt, matching a timeline row's. Saved articles are the same kind of
    /// text in the same style, and a second list at a different density is the inconsistency this
    /// figure exists to avoid.
    var lineHeight: Double = ReadingSettings.defaultLineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SourceIcon(
                    urlString: entry.iconURLString ?? sourceIconURLString,
                    fallbackSystemImage: entry.kind == .status
                        ? "bubble.left.and.bubble.right"
                        : "dot.radiowaves.up.forward",
                    size: 14
                )

                Text(entry.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Saved-at, not published-at: in this list the useful question is "when did I put
                // this aside", not "when was it written".
                // Ages on screen, and carries its own spoken label — see `RelativeTimestamp`.
                RelativeTimestamp(date: entry.addedAt)
                    .font(.caption)
                    // With the source name, matching a timeline row's timestamp — the two lists
                    // occupy the same column and a reader switches between them, so a saved-at
                    // that sat a step darker than a published-at read as a different kind of
                    // fact. See `ItemRow` for why `.tertiary` was too far down in dark mode.
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)

                if entry.archivedHTML != nil {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        // With the timestamp it sits beside. It stays distinguishable on size and
                        // shape — a filled glyph against digits — and at `.tertiary` a badge this
                        // small was nearly gone in dark mode, which is the appearance it is most
                        // often looked for in.
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved for offline reading")
                }
            }

            Text(entry.title)
                .scaledFont(.headline, weight: .semibold, scale: headingScale)
                .lineLimit(2)

            if !entry.excerpt.isEmpty {
                Text(entry.excerpt)
                    .scaledFont(.subheadline, scale: bodyScale, lineHeight: lineHeight)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        // Matching a timeline row's, for the reason given there.
        .padding(.vertical, 6)
    }
}
