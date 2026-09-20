import MastodonAPI
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

/// Which column holds keyboard focus. Tracked explicitly so the left/right arrows can hand focus
/// between columns instead of being swallowed by the focused list.
public enum FocusedColumn: Hashable, Sendable {
    case sidebar
    case timeline
    case detail
}

/// The app's three-column shell.
///
/// One `NavigationSplitView` serves macOS, iPad and iPhone. On the Mac and a landscape iPad it is
/// three columns; on iPhone it collapses to a push stack automatically. Deliberately not branched
/// per platform — those differences are ones `NavigationSplitView` already handles, and forking
/// here would mean maintaining two navigation models.
public struct RootView: View {

    @Environment(\.modelContext) private var modelContext

    @Environment(AppServices.self) private var services

    @Environment(SettingsModel.self) private var settings

    @State private var counts = ThresholdCounts()

    /// Owned by the shell rather than by whichever view was clicked. A timeline row is recycled
    /// the moment it scrolls off, taking any sheet presented from it along; presenting from here
    /// means an arriving refresh cannot close the picture you are looking at.
    @State private var mediaViewer = MediaViewerModel()

    /// Same reasoning as the media viewer: presented from the shell, so a link tapped in a
    /// timeline row is not dismissed by the row being recycled underneath it.
    @State private var browser = InAppBrowserModel()

    /// Steps once a minute so the relative timestamps in the lists age while they are being read.
    ///
    /// Owned by the shell and put in the environment rather than started per list, so a reader
    /// switching between the timeline and Read Later does not restart it, and so both columns
    /// measure against the same instant. See `RelativeClock`.
    @State private var relativeClock = RelativeClock()
    /// Optional because `List(selection:)` requires an optional binding — the non-optional
    /// form resolves to a macOS-only initialiser. Seeded to `.all` so the app opens on the
    /// unified timeline rather than an empty pane.
    @State private var selectedScope: ScopeID? = .all
    @State private var selectedItemID: String?

    /// Owned here because `.focused` needs `@FocusState`, which cannot be passed to child views as
    /// an ordinary `Binding`. Children ask to move focus through a closure instead, which also
    /// keeps them previewable in isolation.
    @FocusState private var focusedColumn: FocusedColumn?

    #if !os(macOS)
    @State private var isShowingSettings = false
    #endif

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(selectedScope: $selectedScope, counts: counts)
                #if !os(macOS)
                // macOS gets the standard `Settings` scene from the app menu instead. On iOS
                // there is no such place, so settings have to be reachable from the sidebar.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                }
                .sheet(isPresented: $isShowingSettings) {
                    SettingsView()
                }
                #endif
                // Without an explicit width the sidebar collapses to around 140pt, which truncates
                // most feed titles before their count badge.
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
                .focused($focusedColumn, equals: .sidebar)
                // From the sidebar, right moves into the timeline. Left is deliberately left to
                // the list so it can still collapse a folder's disclosure.
                .onKeyPress(.rightArrow) {
                    focusedColumn = .timeline
                    return .handled
                }
        } content: {
            TimelineView(
                scope: selectedScope ?? .all,
                selectedItemID: $selectedItemID,
                counts: counts,
                moveFocus: { focusedColumn = $0 }
            )
            // Wide enough for a title plus a three-line excerpt to be worth reading, but capped
            // so the article column keeps a comfortable measure.
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
            .focused($focusedColumn, equals: .timeline)
        } detail: {
            DetailView(
                itemID: $selectedItemID,
                scope: selectedScope ?? .all,
                moveFocus: { focusedColumn = $0 }
            )
            .focused($focusedColumn, equals: .detail)
        }
        // Raised here, at the window, rather than where the action started: a Like is started from
        // a context menu, which has closed by the time the instance answers, and an alert attached
        // to something inside a menu never gets presented.
        .alert(
            "Could not do that",
            isPresented: Binding(
                get: { services.lastActionFailure != nil },
                set: { if !$0 { services.lastActionFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { services.lastActionFailure = nil }
        } message: {
            // Built case by case by `AppServices`, never interpolated from the underlying error: a
            // client error can carry the request whose header holds the access token.
            Text(services.lastActionFailure ?? "")
        }
        .environment(mediaViewer)
        .environment(relativeClock)
        // Started here because the clock lives here. It runs for as long as the shell does, which
        // on the Mac is the whole session.
        .task { await relativeClock.run() }
        .mediaViewer(mediaViewer)
        .inAppBrowser(browser)
        // Installed once, here, rather than at each of the eight places that open a link.
        //
        // `openURL` is also what SwiftUI uses for a tappable link *inside* text — a link in a
        // Mastodon post, an author's address in an article — so overriding it is the only seam
        // that catches those as well. Wiring each button individually would have caught the
        // buttons and quietly missed every link in the content, which is most of them.
        .environment(\.openURL, OpenURLAction { url in
            switch LinkPolicy.destination(
                for: url,
                opensInApp: settings.reading.opensLinksInApp
            ) {
            case .inAppBrowser:
                browser.open(url)
                return .handled
            case .system:
                return .systemAction
            }
        })
        .refreshable {
            await services.refreshNow()
        }
        // Refresh is declared over the timeline column instead — see `TimelineView.body`. It
        // belongs beside the list it refills rather than on the window, and here it sat at the far
        // end of the merged strip next to the reading pane's own buttons.
        .task {
            // First of all, and before any count or list is built: the timeline's sort key
            // changed basis, so a store written by an earlier build holds items and markers that
            // do not compare with each other. See `SortBasisMigration`.
            _ = try? SortBasisMigration.runIfNeeded(
                deviceID: DeviceIdentity.current.id,
                in: modelContext
            )

            // A second, credential-less copy of an account arrives by sync and then fails every
            // refresh — which used to drag every healthy account into the retry backoff with it.
            // Local only: pushing these deletions would remove the other device's working copy.
            // Off the main actor: it reads the Keychain per account, and a synchronous Keychain
            // read on the main actor can stop dead behind a SecurityAgent prompt.
            let container = modelContext.container
            _ = try? await Task.detached {
                try AccountDeduplication.removeUnusableDuplicates(in: ModelContext(container))
            }.value

            // Before anything counts: an account switched off on another device arrives by sync
            // with no toggle to run, and a store written before the flag existed has every item
            // marked enabled. Both leave the timeline showing items it should not.
            _ = try? ThresholdService.reconcileAccountVisibility(in: modelContext)

            // Folder and feed markers written before positions cascaded are still sitting where
            // first sync left them, so their counts read far higher than the `All Items` count
            // that contains them. See `reconcileScopeContainment`.
            if let repaired = try? ThresholdService.reconcileScopeContainment(
                deviceID: DeviceIdentity.current.id,
                in: modelContext
            ), !repaired.isEmpty {
                for mark in repaired {
                    try? SyncOutbox.record(mark, in: modelContext)
                }
                try? modelContext.save()
            }

            // Statuses already in the store are never re-fetched — the walk stops at the first
            // known id — so a column added after they landed stays empty unless it is filled in
            // from the payload they already carry.
            let backfill = StatusBackfill(modelContainer: modelContext.container)
            _ = try? await backfill.fillMissingAuthorHandles()
            _ = try? await backfill.fillMissingMediaMetadata()
            _ = try? await backfill.fillMissingBoostAttribution()
            _ = try? await backfill.fillMissingLinkCards()
            _ = try? await backfill.fillMissingInteractionState()

            counts.startObserving(context: modelContext)
            await services.start()
            // The timeline is where the arrow keys matter most, so it starts focused rather than
            // making every launch begin with a click.
            focusedColumn = .timeline
        }
        // Changing scope must clear the detail column: leaving the previous article on screen
        // beside a timeline that has changed underneath it reads as a rendering bug.
        .onChange(of: selectedScope) {
            selectedItemID = nil
        }
    }
}

#if DEBUG
#Preview {
    RootView()
        .modelContainer(FixtureData.previewContainer())
        .environment(SettingsModel())
}
#endif
