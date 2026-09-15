import ReadReadModel
import SwiftData
import SwiftUI

/// Feed sources and their above-threshold counts.
struct SidebarView: View {

    @Binding var selectedScope: ScopeID?
    let counts: ThresholdCounts

    @Environment(SettingsModel.self) private var settings

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \AccountRecord.createdAt) private var accounts: [AccountRecord]
    @Query(sort: \CachedSource.sortIndex) private var sources: [CachedSource]

    private var sections: [SidebarSection] {
        SidebarTree.build(accounts: accounts, sources: sources)
    }

    var body: some View {
        List(selection: $selectedScope) {
            ForEach(sections) { section in
                if let title = section.title {
                    Section(title) {
                        rows(section.rows)
                    }
                } else {
                    Section {
                        rows(section.rows)
                    }
                }
            }
        }
        // `.sidebar` and no explicit background is what earns the Liquid Glass treatment: setting
        // a custom list background would opt the whole column out of it.
        .listStyle(.sidebar)
        .navigationTitle("ReadRead")
        .onChange(of: sections) { _, updated in
            // Track every scope the sidebar can display, so each row has a count ready rather
            // than filling in one frame late as it scrolls into view.
            track(updated)
        }
        .task {
            track(sections)
        }
        // Re-tracked when the setting is switched, since it decides whether the filtered count is
        // computed at all.
        .onChange(of: settings.reading.showsFilteredItemsBadge) {
            track(sections)
        }
    }

    /// Starts keeping the counts each row will need.
    ///
    /// Filtered Items is left out unless its count is actually shown, and that is a cost decision
    /// rather than tidiness: counting it means `COUNT(*) WHERE isFilteredOut`, and `isFilteredOut`
    /// carries no index of its own — so it is a scan of the whole item table on every recount, for
    /// a number that by default is not on screen.
    private func track(_ sections: [SidebarSection]) {
        let scopes = sections
            .flatMap { $0.rows.flatMap(\.selfAndDescendants) }
            .map(\.scope)
            .filter { $0 != .filtered || settings.reading.showsFilteredItemsBadge }

        counts.track(scopes, in: modelContext)
    }

    /// Rows are handed the counts *object*, not a count.
    ///
    /// This view must not read `newerCount` itself. The open timeline reports its position live, so
    /// that value changes on every scroll — and reading it here would rebuild the whole `List` each
    /// time, which costs the window its first responder: the timeline stops responding to the arrow
    /// keys and to Page Up/Down entirely. Reading it one level down confines the update to the
    /// badge that is actually changing.
    @ViewBuilder
    private func rows(_ rows: [SidebarRow]) -> some View {
        ForEach(rows) { row in
            if row.children.isEmpty {
                SidebarRowView(row: row, counts: counts)
                    .tag(row.scope)
                    .contextMenu { menu(for: row) }
            } else {
                DisclosureGroup {
                    ForEach(row.children) { child in
                        SidebarRowView(row: child, counts: counts)
                            .tag(child.scope)
                            .contextMenu { menu(for: child) }
                    }
                } label: {
                    SidebarRowView(row: row, counts: counts)
                        .tag(row.scope)
                        .contextMenu { menu(for: row) }
                }
            }
        }
    }

    /// Per-feed settings. Only feeds have any, so every other row gets no menu at all rather than
    /// an empty one.
    @ViewBuilder
    private func menu(for row: SidebarRow) -> some View {
        if case .feed(let sourceID) = row.kind, let source = source(sourceID) {
            FeedContextMenu(source: source)
        }
    }

    private func source(_ id: String) -> CachedSource? {
        sources.first { $0.id == id }
    }
}

/// The context menu on a feed row.
///
/// A separate view so it takes a `@Bindable` source: a `Toggle` bound through a computed property
/// on the parent would not observe the model, and the checkmark would only catch up when something
/// else happened to redraw the sidebar.
private struct FeedContextMenu: View {

    @Bindable var source: CachedSource

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        Toggle("Load Full Page Content", isOn: $source.loadsFullPageContent)
            .onChange(of: source.loadsFullPageContent) { _, _ in
                try? modelContext.save()
            }

        Toggle("Load Comments", isOn: $source.loadsComments)
            .onChange(of: source.loadsComments) { _, _ in
                try? modelContext.save()
            }

        if let homepage = source.homepageURL {
            Divider()
            Button("Open Website") { openURL(homepage) }
        }
    }
}

/// One sidebar row: icon, title, and the count of items above this scope's threshold.
struct SidebarRowView: View {

    let row: SidebarRow
    let counts: ThresholdCounts

    @Environment(SettingsModel.self) private var settings

    private var count: Int { counts.newerCount(for: row.scope) }

    /// Whether this row shows a number at all.
    ///
    /// Every other count in the sidebar is items waiting above a reading position. Filtered Items
    /// has no position — its count is the size of the list — so a number there would read as a
    /// backlog when it is really a report on the rules doing their job. Off unless asked for; see
    /// `ReadingSettings.showsFilteredItemsBadge`.
    private var showsCount: Bool {
        guard count > 0 else { return false }
        guard case .filtered = row.kind else { return true }
        return settings.reading.showsFilteredItemsBadge
    }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(row.title)
                    .lineLimit(1)
            } icon: {
                SourceIcon(urlString: row.iconURLString, fallbackSystemImage: row.systemImage)
            }

            // Keeps the count pinned to the trailing edge while the title truncates, rather than
            // letting a long feed name push the count off the row.
            Spacer(minLength: 4)

            if showsCount {
                countBadge
            }
        }
        // Stated explicitly because it is otherwise unreliable: an accessibility dump of the
        // running app showed some rows exposing their title, some exposing only the badge number,
        // and some exposing nothing at all — a `Label` whose icon is an `AsyncImage`, wrapped in a
        // `.badge`, does not compose into a predictable element. Collapsing the row into one
        // element with a stated label and value makes every row read the same way.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        // Keyed on `showsCount`, not on the count: announcing a number the row does not show would
        // make the badge setting a sighted-only preference.
        .accessibilityValue(showsCount ? Text("^[\(count) item](inflect: true)") : Text(verbatim: ""))
    }

    /// The count, as a filled capsule rather than the trailing grey text `.badge` produces.
    ///
    /// Hand-built because `.badge` renders as plain secondary text in a macOS sidebar, which reads
    /// as part of the row rather than as a count — the same problem the Mail and Reeder sidebars
    /// solve with a pill.
    private var countBadge: some View {
        Text(count, format: .number)
            .font(.caption.weight(.semibold))
            // So the pill does not change width between equally-wide numbers as counts tick over
            // during a refresh, which reads as the row twitching.
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            // `.fill.tertiary`, not `.quaternary`. The latter is a *content* colour — near-white
            // in dark mode — so the pill came out light with light text on it and the number was
            // unreadable. The `fill` hierarchy is the one meant for backgrounds and inverts with
            // the scheme the way this needs.
            .background(.fill.tertiary, in: .capsule)
            // The accessibility value on the row already states the count, so exposing the pill
            // separately would have every row read its number twice.
            .accessibilityHidden(true)
    }
}

/// A source's favicon, falling back to a symbol when there is none or it fails to load.
///
/// A feed without a favicon is common, not exceptional — so the fallback is a designed state
/// rather than an error state, and the row's height must not change between the two.
struct SourceIcon: View {

    let urlString: String?
    let fallbackSystemImage: String

    var size: CGFloat = 16

    /// Computed rather than stored: a stored `private` property makes the synthesised memberwise
    /// initialiser private too, and every caller of `SourceIcon(urlString:...)` stops compiling.
    private var store: RemoteImageStore { .shared }

    var body: some View {
        Group {
            // `RemoteImageStore` rather than `AsyncImage`: the latter keeps no decoded cache, so
            // every timeline re-render re-decoded a favicon per row. That was the bulk of the CPU
            // the iPhone was burning while scrolling.
            if let url = urlString.flatMap(URL.init(string:)), let image = store.image(for: url) {
                image.resizable().scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        // Decorative in every one of its call sites: the feed's name, the author's name or the
        // sidebar row's own title sits immediately beside it and says the same thing. Left
        // exposed, the *fallback* is the loud case — a bare `Image(systemName:)` is announced
        // from its symbol name, so a timeline of feeds without favicons had VoiceOver reading
        // "dot radiowaves up forward" ahead of every headline.
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemImage)
            .imageScale(.medium)
            .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var scope: ScopeID? = .all

    NavigationSplitView {
        SidebarView(selectedScope: $scope, counts: ThresholdCounts())
    } detail: {
        Text(verbatim: scope?.rawValue ?? "none")
    }
    .modelContainer(FixtureData.previewContainer())
    .environment(SettingsModel())
}
#endif
