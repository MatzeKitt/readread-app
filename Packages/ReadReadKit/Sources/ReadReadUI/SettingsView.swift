import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// The preferences window on macOS, and a presented sheet on iOS.
///
/// One view for both, because everything it edits is the same on both platforms. The only
/// difference is the container: `TabView` reads as a preferences window on the Mac, while on iOS
/// the same tabs would be a bottom bar in a modal sheet, which is not what settings look like
/// there — so iOS gets the sections stacked in one scrolling `Form` instead.
public struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        #if os(macOS)
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsTab()
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab()
            }
            Tab("Refreshing", systemImage: "arrow.clockwise") {
                RefreshSettingsTab()
            }
            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") {
                FilterSettingsTab()
            }
        }
        // Sized rather than left to fit its content: a preferences window that resizes as you
        // switch tabs is the classic tell of an unconsidered settings screen.
        .frame(width: 580, height: 480)
        #else
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Accounts") { AccountSettingsTab() }
                }
                GeneralSettingsSections()
                RefreshSettingsSections()
                Section {
                    NavigationLink("Filters") { FilterListView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A sheet with no way out but a swipe. The swipe works, but it is not discoverable
                // and it is not available at all once a `NavigationLink` has pushed a subscreen.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    var body: some View {
        Form { GeneralSettingsSections() }
            .formStyle(.grouped)
    }
}

private struct GeneralSettingsSections: View {

    @Environment(SettingsModel.self) private var settings

    @Query(sort: \CachedSource.title) private var sources: [CachedSource]

    var body: some View {
        @Bindable var settings = settings

        Section("Reading") {
            Toggle("Keep an offline copy of saved articles", isOn: $settings.reading.archivesReadLaterContent)
                .help("Saved items stay readable after the feed drops them or the page disappears.")

            Toggle("Mark items that arrived late", isOn: $settings.reading.showsLateArrivalBadges)
                .help("Explains why an item that has just arrived is sitting far down the list.")

            Toggle("Count filtered items in the sidebar", isOn: $settings.reading.showsFilteredItemsBadge)
                .help("Filtered Items normally carries no count, because nothing in it is waiting to be read.")

            // iOS only, because there is nothing to choose on the Mac: a link opens in the
            // browser the reader has already chosen, in a window they can keep.
            #if !os(macOS)
            Toggle("Open links in the app", isOn: $settings.reading.opensLinksInApp)
                .help("Opens a tapped link in Safari inside ReadRead, so you keep your place in the timeline.")
            #endif
        }

        Section {
            TextScalePicker("List headings", selection: $settings.reading.listHeadingScale)
            TextScalePicker("List text", selection: $settings.reading.listBodyScale)
            TextScalePicker("Article text", selection: $settings.reading.contentScale)

            LineHeightStepper(
                "Line height",
                value: $settings.reading.contentLineHeight
            )
        } header: {
            Text("Text Size")
        } footer: {
            // Said plainly, because the alternative reading — that this replaces the system
            // setting — would make anyone relying on Larger Text avoid it.
            Text("Applied on top of the system text size rather than instead of it.")
        }

        #if os(macOS)
        // Not on iOS: there is no hardware keyboard to bind, and offering shortcuts that nothing
        // can press is worse than not offering them. The bindings are still honoured if a keyboard
        // is attached — they simply are not editable here.
        ShortcutSettingsSection(settings: settings)
        #endif

        Section {
            Toggle("Load the whole conversation", isOn: $settings.reading.loadsMastodonThreads)
                .help("Fetches the replies and the posts above every time you open one.")
        } header: {
            Text("Mastodon")
        } footer: {
            // Says what the cost is, since that is the only reason it is not simply on.
            Text("Off by default: loading a conversation is an extra request to your instance for every post you open. With it off, a post that has one offers a button instead.")
        }

        Section("Badge") {
            Picker("Count items in", selection: badgeScope) {
                Text("All Items").tag(ScopeID.all)
                ForEach(sources.filter(\.isSubscribed)) { source in
                    Text(source.title).tag(source.scope)
                }
            }

            Toggle("Include items that arrived late", isOn: $settings.refresh.badgeIncludesLateArrivals)
                .help("Off by default: a late arrival sits below your position, so counting it would advertise something you cannot find by scrolling to the top.")
        }
    }

    /// Bound through a computed binding rather than `$settings.refresh.badgeScope`, because
    /// `badgeScope` is a computed property over the stored raw string and so has no key path a
    /// `@Bindable` projection can reach.
    private var badgeScope: Binding<ScopeID> {
        Binding(
            get: { settings.refresh.badgeScope },
            set: { settings.refresh.badgeScope = $0 }
        )
    }
}

// MARK: - Refreshing

private struct RefreshSettingsTab: View {
    var body: some View {
        // A stack of its own, like the accounts and filters tabs, for the log the background
        // section pushes: a `Settings` tab provides no navigation.
        NavigationStack {
            Form { RefreshSettingsSections() }
                .formStyle(.grouped)
        }
    }
}

/// Everything background refreshing has done lately, newest first.
///
/// For diagnosing a phone that never refreshes in the background, which cannot be done by looking
/// at it: the system gives no reason for waiting, and the runs happen with nobody watching. The
/// entries' details are left in English, since they are system evidence meant to be shared into a
/// bug report rather than read as copy.
private struct BackgroundRefreshLogView: View {

    @State private var entries = BackgroundRefresh.diagnostics.log

    var body: some View {
        List {
            if entries.isEmpty {
                Text("Nothing has happened yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Self.title(for: entry.event)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let trigger = entry.trigger {
                        Self.title(for: trigger)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = entry.detail {
                        Text(verbatim: detail)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Background Refresh Log")
        .toolbar {
            ToolbarItem {
                ShareLink(item: BackgroundRefresh.logText(entries))
                    .disabled(entries.isEmpty)
            }
        }
        .refreshable { entries = BackgroundRefresh.diagnostics.log }
        .task { entries = BackgroundRefresh.diagnostics.log }
    }

    private static func title(for event: BackgroundRefresh.LogEntry.Event) -> Text {
        switch event {
        case .scheduled: Text("Request queued")
        case .declined: Text("Request turned down")
        case .runStarted: Text("Background refresh started")
        case .runFinished: Text("Background refresh finished")
        case .runExpired: Text("Background refresh cut short")
        case .statusChanged: Text("Background App Refresh changed")
        case .registered: Text("Background task registered")
        case .registrationFailed: Text("Background task not registered")
        case .pendingChecked: Text("Pending requests checked")
        }
    }

    private static func title(for trigger: BackgroundRefresh.Trigger) -> Text {
        switch trigger {
        case .launch: Text("At launch")
        case .activated: Text("On returning to the app")
        case .enteredBackground: Text("On leaving the app")
        case .backgroundRun: Text("From a background refresh")
        case .settingsChanged: Text("After a settings change")
        case .statusChanged: Text("After Background App Refresh changed")
        case .retry: Text("Tried again")
        }
    }
}

private struct RefreshSettingsSections: View {

    @Environment(SettingsModel.self) private var settings
    @Environment(AppServices.self) private var services

    /// What refreshing while nobody was looking has actually done, as of the last time this screen
    /// opened.
    ///
    /// On both platforms now. It was iOS-only, on the reasoning that the diary is written by
    /// `BGAppRefreshTask` launches and the Mac has no `BGTaskScheduler` — true of the *scheduling*,
    /// and it left the Mac with no answer at all to the question these rows exist for. A Mac sits
    /// behind other windows for most of the day and refreshes there through its own timers; see
    /// `AppServices.record(_:)`, which is what fills this in.
    @State private var background = BackgroundRefresh.diagnostics

    /// The system's own answer to whether a request is queued. See
    /// ``BackgroundRefresh/pendingRequest()``.
    @State private var pending: BackgroundRefresh.PendingRequest?

    #if os(iOS)
    @State private var systemStatus = UIBackgroundRefreshStatus.available
    #endif

    /// What the timers have been doing, re-read while this screen is open.
    @State private var cadences = RefreshCoordinator.Diagnostics()

    var body: some View {
        @Bindable var settings = settings

        Section {
            intervalPicker(
                "Reading position",
                kind: .syncState,
                choices: RefreshSettings.syncStateChoices
            )
            intervalPicker(
                "Mastodon",
                kind: .mastodonFeeds,
                choices: RefreshSettings.mastodonChoices
            )
            intervalPicker(
                "Feeds",
                kind: .freshRSSFeeds,
                choices: RefreshSettings.freshRSSChoices
            )
        } header: {
            Text("How often")
        } footer: {
            // Worth saying, because the three-way split otherwise looks like fussiness rather than
            // the deliberate cost trade-off it is.
            Text("A position check is a few hundred bytes, so it can run often. Fetching feeds is far more expensive — and a Mastodon timeline moves much faster than an RSS river.")
        }

        Section {
            Picker("Fetch items from", selection: $settings.refresh.historyWindowDays) {
                ForEach(HistoryWindow.choices, id: \.self) { days in
                    Text(HistoryWindow.title(forDays: days)).tag(days)
                }
            }
        } header: {
            Text("How far back")
        } footer: {
            // Both halves are worth saying. The first because a new account otherwise silently
            // downloads a decade of archive on its first refresh; the second because widening the
            // window costs one full pass and people should know why that refresh is slow.
            Text("Bounds what a refresh fetches — a new account pulls a week rather than every article its feeds have ever published. Items already downloaded stay until they are pruned, and widening this re-reads each feed once.")
        }

        Section("When") {
            Toggle("Pause while no window is visible", isOn: $settings.refresh.pauseWhenHidden)
                .help("Catches up as soon as a window comes back.")

            Toggle("Slow down in Low Power Mode", isOn: $settings.refresh.respectLowPowerMode)
        }

        // Shown because unattended refreshing cannot be observed any other way. A timeline that
        // has not changed looks the same whether the timers are running and the feeds are quiet,
        // whether they are paused behind a hidden window, or whether every run has been failing
        // into a backoff that is now half an hour long — three different problems with three
        // different fixes and nothing on screen to tell them apart.
        Section {
            ForEach(cadences.cadences) { cadence in
                LabeledContent(Self.title(for: cadence.kind)) {
                    cadenceState(cadence)
                }
            }

            if cadences.isPaused {
                #if os(macOS)
                // Reworded because the sentence was true and read as bad news. The pause is now
                // only half the story: the system's own scheduler keeps refreshing behind a
                // hidden window, which is the thing a reader wants to know here.
                note(
                    "The app's own cadences are paused because no window is visible. macOS keeps refreshing in the background, and the cadences catch up as soon as a window is back.",
                    systemImage: "pause.circle"
                )
                #else
                note(
                    "Refreshing is paused because no window is visible. It catches up as soon as one is.",
                    systemImage: "pause.circle"
                )
                #endif
            }

            LabeledContent("Last background refresh") {
                if let date = background.lastRunAt {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }

            if background.runCount > 0 {
                LabeledContent("Background refreshes") {
                    Text(background.runCount, format: .number)
                }
            }

            #if os(iOS)
            // What the system says, beside what the app remembers. The diary records the answer
            // to the last submit; these two are read live, and a disagreement between them is
            // itself the finding.
            LabeledContent("Background App Refresh") {
                systemStatusText
            }
            #endif

            LabeledContent("Next background refresh") {
                if let pending, let earliest = pending.earliestBeginDate {
                    Text("Not before \(earliest, format: .dateTime.hour().minute())")
                } else if pending != nil {
                    Text("Scheduled")
                } else {
                    Text("Not scheduled")
                }
            }

            // Both platforms, because both have something to decline. On iOS the system can
            // refuse a `BGAppRefreshTask` outright; on the Mac the request is an
            // `NSBackgroundActivityScheduler` and the only way it is not queued is refreshing
            // being switched off altogether, which is worth saying rather than leaving as a
            // silent "Never" above.
            if let refusal = background.refusal {
                refusalNote(refusal)

                if refusal != .cadencesOff {
                    Button("Try Again") {
                        services.retryBackgroundRefresh()
                        Task { await reloadBackground() }
                    }

                    #if os(iOS)
                    // Background App Refresh has no permission prompt to show again — iOS offers
                    // none, for this switch — so the way back is the app's page in Settings.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                    }
                    #endif
                }
            } else if background.isRequestQueued, pending == nil, background.lastScheduledAt != nil {
                // Accepted and then not held: `submit` returns normally while the scheduler rejects
                // the request on its own side, which is what a sideloaded phone did for days. The
                // diary alone reported that as queued.
                note(
                    "iOS accepted the last request but is not holding it, so it will not run. The log below has the details.",
                    systemImage: "exclamationmark.triangle"
                )
            } else if !background.isRequestQueued {
                // Declined by a build from before the reason was kept.
                note(
                    "The last request was turned down. Try again to find out why.",
                    systemImage: "exclamationmark.triangle"
                )
                Button("Try Again") {
                    services.retryBackgroundRefresh()
                    Task { await reloadBackground() }
                }
            }

            NavigationLink("Log") {
                BackgroundRefreshLogView()
            }
        } header: {
            Text("In the background")
        } footer: {
            #if os(iOS)
            Text("iOS decides when a closed app may refresh, and it can be a long wait. Swiping ReadRead away in the app switcher stops it being asked at all. The times above are the app's own cadences, which run while it is open.")
            #else
            Text("The times above are the app's own cadences, which run while a window is visible; a failing server is retried at a widening interval rather than every cycle. Behind a hidden window macOS itself schedules the refreshing, at a moment of its choosing near the shortest cadence above — that is what the count below reports. Nothing can wake ReadRead once it has quit: macOS has no equivalent of the background launch iOS gives a closed app.")
            #endif
        }
        .task {
            // Re-read each time the screen opens rather than observed: these are four keys in
            // `UserDefaults`, written on iOS by a process that is usually gone by the time anyone
            // looks, and on the Mac by a refresh that happened while this window was behind
            // something else.
            await reloadBackground()

            // Polled rather than observed, and deliberately. The coordinator is an actor holding
            // scheduling state, not view state; making it `@Observable` would put the hot path of
            // every timer tick through the main actor to serve a screen that is almost never open.
            // A snapshot every few seconds is enough for "when did it last run", which is the
            // question, and the loop ends with the screen.
            while !Task.isCancelled {
                cadences = await services.refreshDiagnostics()
                // Re-read with the cadences rather than only on open. On the Mac this screen can
                // be sitting in a window behind another app — which is precisely the state in
                // which an unattended refresh gets recorded, so the figure would otherwise be
                // stale exactly when it was changing.
                await reloadBackground()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    /// The same names the pickers above use, so the two halves of this screen agree.
    ///
    /// Not `RefreshKind.displayName`. That is a `String`, which means it is never extracted for
    /// translation and would print these three rows in English inside an otherwise German screen —
    /// while the literals here are the *same keys* the interval pickers use, so they are one
    /// catalogue entry and one translation each.
    private static func title(for kind: RefreshKind) -> LocalizedStringKey {
        switch kind {
        case .syncState: "Reading position"
        case .mastodonFeeds: "Mastodon"
        case .freshRSSFeeds: "Feeds"
        }
    }

    /// One cadence's line: when it last ran, and what it is doing now.
    ///
    /// "Never" is a real answer here and not an error — a cadence switched off has never run and
    /// never will, which is why the off case is stated rather than left as an empty dash.
    @ViewBuilder
    private func cadenceState(_ cadence: RefreshCoordinator.Diagnostics.Cadence) -> some View {
        if cadence.isRunning {
            Text("Running now")
        } else if cadence.nextDueAt == nil {
            // The same word the picker above uses for this cadence's interval, deliberately: a
            // cadence set to Never is off because it was set that way, not because it is stuck.
            Text("Never")
        } else if cadence.failureCount > 0 {
            // The failure count rather than the error itself, and in place of the time rather than
            // beside it: what an unchanged timeline needs explaining is the *silence*, and a run
            // that failed a minute ago is worse news than one that succeeded an hour ago. The
            // error's own text belongs to the accounts screen, where it can be acted on.
            Text("^[\(cadence.failureCount) failure](inflect: true) in a row")
        } else if let last = cadence.lastRunAt {
            Text(last, format: .relative(presentation: .named))
        } else {
            Text("Not yet")
        }
    }

    private func reloadBackground() async {
        background = BackgroundRefresh.diagnostics
        pending = await BackgroundRefresh.pendingRequest()
        #if os(iOS)
        systemStatus = BackgroundRefresh.systemStatus
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var systemStatusText: some View {
        switch systemStatus {
        case .available: Text("On")
        case .denied: Text("Off")
        case .restricted: Text("Restricted")
        @unknown default: Text("Unknown")
        }
    }
    #endif

    /// Why nothing is queued, in the words that point at the fix.
    ///
    /// One sentence per `BGTaskScheduler` refusal rather than one for all of them. The single
    /// sentence this replaces blamed the Settings switch, which is only one of the three — and on
    /// the phone that prompted this, the switch was on.
    @ViewBuilder
    private func refusalNote(_ refusal: BackgroundRefresh.Refusal) -> some View {
        switch refusal {
        case .cadencesOff:
            note(
                "Nothing is scheduled, because every cadence above is switched off.",
                systemImage: "exclamationmark.triangle"
            )
        case .unavailable:
            #if os(iOS)
            if systemStatus == .denied {
                note(
                    "iOS turned down the last request because Background App Refresh is off for ReadRead, or for the whole device.",
                    systemImage: "exclamationmark.triangle"
                )
            } else if systemStatus == .restricted {
                note(
                    "iOS turned down the last request because Background App Refresh is restricted on this device, for example by Screen Time or a management profile.",
                    systemImage: "exclamationmark.triangle"
                )
            } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
                note(
                    "iOS turned down the last request because Low Power Mode is on.",
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                note(
                    "iOS turned down the last request, although Background App Refresh is on now. Try again; if it is turned down again, the log below has the details.",
                    systemImage: "exclamationmark.triangle"
                )
            }
            #else
            note(
                "The last request was turned down.",
                systemImage: "exclamationmark.triangle"
            )
            #endif
        case .tooManyPendingRequests:
            note(
                "The last request was turned down because too many are already waiting.",
                systemImage: "exclamationmark.triangle"
            )
        case .notPermitted:
            note(
                "The last request was turned down because this build does not declare its background task. That is a bug in ReadRead.",
                systemImage: "exclamationmark.triangle"
            )
        case .unknown:
            note(
                "The last request was turned down for a reason the system did not name. The log below has the details.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    /// A quiet explanatory line, for the states that need a sentence rather than a value.
    private func note(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func intervalPicker(
        _ title: LocalizedStringKey,
        kind: RefreshKind,
        choices: [Int?]
    ) -> some View {
        Picker(title, selection: interval(for: kind)) {
            ForEach(choices, id: \.self) { choice in
                Text(Self.label(for: choice)).tag(choice)
            }
        }
    }

    private func interval(for kind: RefreshKind) -> Binding<Int?> {
        Binding(
            get: { settings.refresh.seconds(for: kind) },
            set: { settings.refresh.setSeconds($0, for: kind) }
        )
    }

    private static func label(for seconds: Int?) -> String {
        guard let seconds else { return "Never" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide)
        )
    }
}

// MARK: - Filters

private struct AccountsTab: View {
    var body: some View {
        // Its own stack for the same reason as the filters tab: a `Settings` tab provides no
        // navigation, and the sheets and dialogs inside want somewhere to hang.
        NavigationStack {
            AccountSettingsTab()
        }
    }
}

private struct FilterSettingsTab: View {
    var body: some View {
        // Kept, though nothing is pushed from here any more: the hidden-items list it used to lead
        // to now lives in the sidebar. `FilterListView` still sets a navigation title, and its
        // `List` is laid out by this stack — dropping it is a visual change to make deliberately
        // rather than as a side effect of moving that list out.
        NavigationStack {
            FilterListView()
        }
    }
}




/// One row of the Text Size section.
///
/// A named picker rather than a slider or a point-size stepper. The values are a small fixed set,
/// and "Large" is a thing a person can choose deliberately in a way that "17.9pt" is not.
private struct TextScalePicker: View {

    private let title: LocalizedStringKey
    @Binding private var selection: TextScale

    init(_ title: LocalizedStringKey, selection: Binding<TextScale>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(TextScale.allCases) { scale in
                Text(scale.title).tag(scale)
            }
        }
    }
}


/// The reading pane's leading, as a multiple of the font size.
///
/// A stepper rather than a picker, because unlike the sizes this is a continuous quantity people
/// have real opinions about to a tenth — and unlike a slider, a stepper can show the number, which
/// is the thing anyone changing line height actually wants to see.
private struct LineHeightStepper: View {

    private static let step = 0.1

    private let title: LocalizedStringKey
    @Binding private var value: Double

    init(_ title: LocalizedStringKey, value: Binding<Double>) {
        self.title = title
        _value = value
    }

    var body: some View {
        // Built as a `LabeledContent` with the stepper *inside* the trailing slot, rather than as a
        // `Stepper` wrapping a label. The two produce visibly different rows: the latter puts the
        // label on the left and full-height arrows on the right, which sits taller and heavier than
        // the pop-up buttons above it. This way the row matches the pickers — title left, value
        // right, control last — and the arrows are the small control size those rows use.
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value, format: .number.precision(.fractionLength(1)))
                    // So the row does not twitch sideways as the number is stepped through
                    // values of different widths.
                    .monospacedDigit()

                Stepper(title, value: $value, in: ReadingSettings.lineHeightRange, step: Self.step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(1))))
    }
}
