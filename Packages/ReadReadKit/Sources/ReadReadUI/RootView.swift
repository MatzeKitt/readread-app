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

    /// The reply composer and the mute confirmation, for the same reason as the two above: both are
    /// started from a timeline row's context menu, and a row is recycled the instant it scrolls off.
    /// See `StatusComposer`.
    @State private var composer = StatusComposer()

    /// The widths the two resizable columns open at, and where a drag is recorded. Read once, at
    /// the window's creation — see `ColumnWidths` for why it must not change while the window is
    /// open.
    @State private var columnWidths = ColumnWidths()

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
                // most feed titles before their count badge. The ideal is whatever it was last
                // dragged to; see `ColumnWidths`.
                .navigationSplitViewColumnWidth(
                    min: ColumnWidths.sidebarLimits.lowerBound,
                    ideal: columnWidths.sidebar,
                    max: ColumnWidths.sidebarLimits.upperBound
                )
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
            // Underneath the width modifier, and it has to be. `navigationSplitViewColumnWidth`
            // writes a trait, and not every modifier passes one on: wrapping the column above it
            // lost both traits outright, and the columns opened at SwiftUI's own 144 and 200
            // points. Anything else a column needs therefore goes on first.
            //
            // Both columns are reported from this one place, because both are read off the single
            // split view that carries them; see `ColumnWidthReporter`.
            .background { ColumnWidthReporter(widths: columnWidths) }
            // Wide enough for a title plus a three-line excerpt to be worth reading, but capped
            // so the article column keeps a comfortable measure. This is the column macOS forgets
            // on its own, which is what `ColumnWidths` is for.
            .navigationSplitViewColumnWidth(
                min: ColumnWidths.timelineLimits.lowerBound,
                ideal: columnWidths.timeline,
                max: ColumnWidths.timelineLimits.upperBound
            )
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
        // A sheet rather than a window, on both platforms: a reply is a short, modal errand with a
        // Cancel, and it is written about a post that is on screen behind it.
        .sheet(item: $composer.replyDraft) { draft in
            ReplyComposerSheet(draft: draft)
        }
        // Confirmed, unlike Like and Boost, because this one cannot be taken back from inside the
        // app: the posts already fetched are deleted, and unmuting on the instance will not bring
        // them back — the ingest walk stops at the first id it already knows. See `AuthorMute`.
        .confirmationDialog(
            muteTitle,
            isPresented: Binding(
                get: { composer.muteRequest != nil },
                set: { if !$0 { composer.dismissMute() } }
            ),
            titleVisibility: .visible,
            presenting: composer.muteRequest
        ) { request in
            Button("Mute", role: .destructive) {
                composer.dismissMute()
                Task { await services.muteAuthor(of: request.item) }
            }
            Button("Cancel", role: .cancel) { composer.dismissMute() }
        } message: { _ in
            Text("Their posts stop arriving, and the ones already here are removed. Unmuting is done on your Mastodon server.")
        }
        .environment(mediaViewer)
        .environment(relativeClock)
        .environment(composer)
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

            let container = modelContext.container

            // Before the deduplication below, and before anything reads a position: account ids
            // used to be minted per device, so the same feed, article and scope were named
            // differently everywhere and no per-feed position could ever sync. This gives them the
            // ids every device derives, and rewrites what is already stored to match.
            //
            // Off the main actor, because it moves each account's Keychain item — and a
            // synchronous Keychain call on the main actor can stop dead behind a SecurityAgent
            // prompt, taking the window with it.
            let deviceID = DeviceIdentity.current.id
            let accountIDs = try? await Task.detached {
                try AccountIDMigration.run(deviceID: deviceID, in: ModelContext(container))
            }.value

            // The one account id the store cannot reach. `badgeScope` is a `ScopeID` kept in the
            // preferences, so a reader whose badge counts one feed would otherwise be left
            // counting a scope that no longer exists — a badge stuck at zero with nothing to say
            // why.
            if let mapping = accountIDs?.accounts, !mapping.isEmpty,
               let rescoped = AccountIDMigration.rewrite(scope: settings.refresh.badgeScope, using: mapping) {
                settings.refresh.badgeScope = rescoped
            }

            // A second, credential-less copy of an account arrives by sync and then fails every
            // refresh — which used to drag every healthy account into the retry backoff with it.
            // Local only: pushing these deletions would remove the other device's working copy.
            // Off the main actor: it reads the Keychain per account, and a synchronous Keychain
            // read on the main actor can stop dead behind a SecurityAgent prompt.
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

    /// Names the person in the question rather than in the body, so the dialog's own title is the
    /// decision being taken. An empty string when nothing is pending, which is never on screen.
    private var muteTitle: String {
        guard let request = composer.muteRequest else { return "" }
        return String(localized: "Mute @\(request.authorHandle)?")
    }
}

#if DEBUG
#Preview {
    RootView()
        .modelContainer(FixtureData.previewContainer())
        .environment(SettingsModel())
}
#endif
