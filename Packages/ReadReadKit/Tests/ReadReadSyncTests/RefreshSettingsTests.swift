import Foundation
import ReadReadModel
import Testing

@testable import ReadReadSync

@Suite("RefreshSettings")
struct RefreshSettingsTests {

    /// The defaults from the plan: sync state often because it is cheap, feeds rarely because they
    /// are not.
    @Test("Defaults match the intended cadences")
    func defaultsAreAsIntended() {
        let settings = RefreshSettings.default

        #expect(settings.syncStateSeconds == 30)
        #expect(settings.mastodonSeconds == 300)
        #expect(settings.freshRSSSeconds == 900)
        #expect(settings.badgeScope == .all)
        // Off by default: a late arrival sits below the marker, so counting it would advertise
        // something the user cannot find by scrolling to the top.
        #expect(settings.badgeIncludesLateArrivals == false)
    }

    @Test("An interval of nil or zero means off", arguments: [nil, 0])
    func nilOrZeroMeansOff(seconds: Int?) {
        var settings = RefreshSettings()
        settings.setSeconds(seconds, for: .freshRSSFeeds)

        #expect(settings.isEnabled(.freshRSSFeeds) == false)
        #expect(settings.interval(for: .freshRSSFeeds, isLowPower: false) == nil)
    }

    @Test("Each kind is read and written independently")
    func kindsAreIndependent() {
        var settings = RefreshSettings()
        settings.setSeconds(60, for: .syncState)
        settings.setSeconds(nil, for: .mastodonFeeds)
        settings.setSeconds(1_800, for: .freshRSSFeeds)

        #expect(settings.seconds(for: .syncState) == 60)
        #expect(settings.seconds(for: .mastodonFeeds) == nil)
        #expect(settings.seconds(for: .freshRSSFeeds) == 1_800)
    }

    /// The ranges differ by an order of magnitude on purpose — a Mastodon timeline moves far
    /// faster than an RSS river.
    @Test("The offered choices suit each kind")
    func choicesSuitEachKind() {
        // Every list offers "off".
        #expect(RefreshSettings.syncStateChoices.contains(nil))
        #expect(RefreshSettings.mastodonChoices.contains(nil))
        #expect(RefreshSettings.freshRSSChoices.contains(nil))

        // Sync state is measured in seconds, feeds in minutes.
        #expect(RefreshSettings.syncStateChoices.compactMap { $0 }.max() == 60)
        #expect(RefreshSettings.freshRSSChoices.compactMap { $0 }.min() == 300)
        // Mastodon can be set faster than FreshRSS.
        let fastestMastodon = RefreshSettings.mastodonChoices.compactMap { $0 }.min() ?? 0
        let fastestFreshRSS = RefreshSettings.freshRSSChoices.compactMap { $0 }.min() ?? 0
        #expect(fastestMastodon < fastestFreshRSS)
    }

    @Test("Low Power Mode multiplies the interval")
    func lowPowerMultiplies() {
        let settings = RefreshSettings(freshRSSSeconds: 900, lowPowerMultiplier: 4)

        #expect(settings.interval(for: .freshRSSFeeds, isLowPower: false) == .seconds(900))
        #expect(settings.interval(for: .freshRSSFeeds, isLowPower: true) == .seconds(3_600))
    }

    @Test("A multiplier below one cannot shorten the interval")
    func multiplierCannotShortenInterval() {
        // Guards against a nonsensical stored value making refreshes *more* frequent on battery.
        let settings = RefreshSettings(freshRSSSeconds: 900, lowPowerMultiplier: 0)

        #expect(settings.interval(for: .freshRSSFeeds, isLowPower: true) == .seconds(900))
    }

    @Test("Only feed kinds ingest items")
    func onlyFeedKindsIngestItems() {
        #expect(RefreshKind.syncState.ingestsItems == false)
        #expect(RefreshKind.mastodonFeeds.ingestsItems)
        #expect(RefreshKind.freshRSSFeeds.ingestsItems)
    }

    // MARK: - Persistence

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "readread-tests-\(UUID().uuidString)")!
        return defaults
    }

    @Test("Settings round-trip through UserDefaults")
    func settingsRoundTrip() {
        let defaults = makeDefaults()
        let store = RefreshSettingsStore(defaults: defaults)

        var settings = RefreshSettings()
        settings.setSeconds(120, for: .mastodonFeeds)
        settings.badgeScope = .source("freshrss:x:feed/1")
        settings.pauseWhenHidden = false
        store.save(settings)

        #expect(RefreshSettingsStore(defaults: defaults).load() == settings)
    }

    @Test("An empty store yields the defaults")
    func emptyStoreYieldsDefaults() {
        #expect(RefreshSettingsStore(defaults: makeDefaults()).load() == .default)
    }

    /// Refresh cadence is a preference, not data. Silently resetting it after a type change is far
    /// better than refusing to refresh at all.
    @Test("Corrupt stored settings fall back to the defaults")
    func corruptSettingsFallBack() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "media.kitt.readread.refreshSettings")

        #expect(RefreshSettingsStore(defaults: defaults).load() == .default)
    }

    // MARK: - Background refresh

    /// The floor is the point of this property. `BGTaskScheduler` decides when it runs a request
    /// and budgets an app by how often it is used, so asking every thirty seconds — which the sync
    /// cadence would ask for — spends that budget on refusals.
    @Test("A background refresh is never asked for more often than the floor")
    func backgroundRefreshIsFloored() {
        let settings = RefreshSettings(syncStateSeconds: 15, mastodonSeconds: 2 * 60)

        #expect(settings.backgroundRefreshSeconds == RefreshSettings.minimumBackgroundSeconds)
    }

    @Test("A background refresh follows the longest-set cadence when all of them are long")
    func backgroundRefreshFollowsTheShortestCadence() {
        let settings = RefreshSettings(
            syncStateSeconds: nil,
            mastodonSeconds: 30 * 60,
            freshRSSSeconds: 60 * 60
        )

        #expect(settings.backgroundRefreshSeconds == 30 * 60)
    }

    /// A reader who has switched refreshing off has switched it off everywhere, including in the
    /// background where they cannot see it happening.
    @Test("Nothing is asked for when every cadence is off")
    func backgroundRefreshIsSkippedWhenEverythingIsOff() {
        let settings = RefreshSettings(
            syncStateSeconds: nil,
            mastodonSeconds: nil,
            freshRSSSeconds: nil
        )

        #expect(settings.backgroundRefreshSeconds == nil)
    }

    /// Zero is how a stored blob from an older build can express "off", and treating it as a
    /// cadence would ask the system for a refresh every no-time-at-all.
    @Test("A zero cadence counts as off, not as immediate")
    func zeroCadenceIsNotAnInterval() {
        let settings = RefreshSettings(
            syncStateSeconds: 0,
            mastodonSeconds: 0,
            freshRSSSeconds: 15 * 60
        )

        #expect(settings.backgroundRefreshSeconds == 15 * 60)
    }

    @Test("The badge scope survives a round trip for every scope kind", arguments: [
        ScopeID.all,
        .readLater,
        .folder("News / Long Reads"),
        .source("freshrss:x:feed/12"),
        .mastodonHome(accountID: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!),
    ])
    func badgeScopeRoundTrips(scope: ScopeID) {
        var settings = RefreshSettings()
        settings.badgeScope = scope

        let defaults = makeDefaults()
        RefreshSettingsStore(defaults: defaults).save(settings)

        #expect(RefreshSettingsStore(defaults: defaults).load().badgeScope == scope)
    }
}
