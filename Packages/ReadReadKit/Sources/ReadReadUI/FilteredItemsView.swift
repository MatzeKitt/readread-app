import ReadReadModel
import SwiftData
import SwiftUI

/// Everything the filter rules are currently hiding.
///
/// Exists because a rule that works is indistinguishable from a rule that is too broad: both make
/// items stop appearing. Without somewhere to look, the only symptom of a bad pattern is a feed
/// that has mysteriously gone quiet — and the natural conclusion is that the app is broken.
struct FilteredItemsView: View {

    @Binding var selectedItemID: String?
    let moveFocus: (FocusedColumn) -> Void

    /// Through `ScopeQuery` rather than a predicate of its own, so the list and the count beside it
    /// are the same question. Written inline they had already drifted: this query showed hidden
    /// items belonging to a switched-off account, which the count deliberately leaves out.
    @Query(
        filter: ScopeQuery.displayPredicate(for: .filtered),
        sort: \CachedItem.sortKeyRaw,
        order: .reverse
    )
    private var items: [CachedItem]

    @Query private var sources: [CachedSource]
    @Query(sort: \FilterRule.createdAt, order: .reverse) private var rules: [FilterRule]

    @Environment(SettingsModel.self) private var settings

    private var sourceTitles: [String: String] {
        Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// The feeds' favicons, since an item carries none of its own. See `ItemRow`.
    private var sourceIcons: [String: String] {
        Dictionary(
            sources.compactMap { source in source.iconURLString.map { (source.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        // Compiled once for the whole list, not once per row. A regex costs far more to build than
        // to run, and `ForEach` would rebuild the engine for every visible cell.
        let engine = FilterEngine(rules)
        let titles = sourceTitles
        let icons = sourceIcons

        List(selection: $selectedItemID) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    ItemRow(
                        item: item,
                        sourceTitle: titles[item.sourceID],
                        sourceIconURLString: icons[item.sourceID],
                        showsLateArrival: false,
                        headingScale: settings.reading.listHeadingScale,
                        bodyScale: settings.reading.listBodyScale,
                        // Passed rather than defaulted: the default happens to equal the setting's
                        // own default, so leaving it out looked right and would have drifted the
                        // moment the reader touched the preference.
                        lineHeight: settings.reading.contentLineHeight
                    )

                    if let rule = engine.firstMatch(
                        for: FilterSubject(item, sourceTitle: titles[item.sourceID])
                    ) {
                        Label("Hidden by “\(rule.name)”", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        // The stored flag and the current rules disagree, which means the rules
                        // were edited and the re-evaluation pass has not reached this row yet.
                        // Saying so beats showing a blank where an explanation should be.
                        Label("No longer matched — waiting to reappear", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
                // Selectable now that this is a column of the main window rather than a page
                // pushed inside Settings: the point of finding a hidden item is usually to read it.
                .tag(item.id)
                // The same marking as the timeline, for the same reason. See `SelectionMarker`.
                .listRowBackground(SelectionMarker(isSelected: selectedItemID == item.id))
            }
        }
        .plainListSelection()
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing Hidden",
                    systemImage: "eye",
                    description: Text("No cached item matches any of your rules.")
                )
            }
        }
        .navigationTitle("Filtered Items")
        // This list had no toolbar of its own, which is exactly why Refresh ended up over the
        // reading pane here: the only declaration was the one on the routing view above, and that
        // one drifts. See the note in `TimelineView.body`. There is nothing else to put in it —
        // a hidden item has no action but to stop being hidden, which happens in the rules.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarButton()
            }
        }
        // As in the other two lists: a click selects a row without focusing the column, which
        // leaves the arrows below with nothing to fire on.
        .activatesColumn(.timeline, onSelecting: selectedItemID, moveFocus: moveFocus)
        // The same column hand-off as the timeline and Read Later, so the arrow keys behave the
        // same way in all three.
        .onKeyPress(.leftArrow) {
            moveFocus(.sidebar)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocus(.detail)
            return .handled
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FilteredItemsView(selectedItemID: .constant(nil), moveFocus: { _ in })
    }
    .modelContainer(FixtureData.previewContainer())
}
#endif
