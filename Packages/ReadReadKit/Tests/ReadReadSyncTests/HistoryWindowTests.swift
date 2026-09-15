import Foundation
import ReadReadModel
import Testing
@testable import ReadReadSync

@Suite("History window")
struct HistoryWindowTests {

    @Test("Seven days is the default, and it resolves to a cutoff a week back")
    func defaultIsAWeek() throws {
        #expect(HistoryWindow.default == 7)
        #expect(RefreshSettings().historyWindowDays == 7)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = try #require(RefreshSettings().historyCutoff(now: now))
        #expect(cutoff.timeIntervalSince1970 == 1_700_000_000 - 7 * 86_400)
    }

    @Test("Everything means no bound at all, not a very large one")
    func unlimitedIsNil() {
        var settings = RefreshSettings()
        settings.historyWindowDays = HistoryWindow.unlimited
        #expect(settings.historyCutoff() == nil)
        #expect(HistoryWindow.cutoff(forDays: 0) == nil)
    }

    /// The setting reaches a URL query and a date comparison, so a negative day count would
    /// silently ask the server for items published in the future.
    @Test("A negative window is treated as no bound rather than an inverted one")
    func negativeIsClamped() {
        #expect(RefreshSettings(historyWindowDays: -5).historyWindowDays == 0)
        #expect(HistoryWindow.cutoff(forDays: -5) == nil)
    }

    @Test("Every offered choice has a name of its own")
    func everyChoiceIsNamed() {
        for days in HistoryWindow.choices {
            let title = HistoryWindow.title(forDays: days)
            #expect(!title.isEmpty)
            // No choice may fall through to the bare "N days" default and read as a duplicate of
            // a named one.
            if days == 0 { #expect(title == "Everything") }
        }
        #expect(Set(HistoryWindow.choices.map(HistoryWindow.title(forDays:))).count == HistoryWindow.choices.count)
    }

    /// Refresh settings are decoded from a blob an older build wrote, and the store treats a
    /// decode failure as "reset everything".
    @Test("A blob written before the window existed keeps every other preference")
    func legacyBlobSurvives() throws {
        let legacy = """
        {"syncStateSeconds":15,"mastodonSeconds":120,"freshRSSSeconds":300,"pauseWhenHidden":false,\
        "respectLowPowerMode":false,"lowPowerMultiplier":2,"badgeScopeRaw":"all",\
        "badgeIncludesLateArrivals":true}
        """
        let settings = try JSONDecoder().decode(RefreshSettings.self, from: Data(legacy.utf8))

        #expect(settings.syncStateSeconds == 15)
        #expect(settings.mastodonSeconds == 120)
        #expect(settings.freshRSSSeconds == 300)
        #expect(settings.pauseWhenHidden == false)
        #expect(settings.respectLowPowerMode == false)
        #expect(settings.lowPowerMultiplier == 2)
        #expect(settings.badgeIncludesLateArrivals == true)

        // And the new field arrives at its default rather than failing the decode.
        #expect(settings.historyWindowDays == HistoryWindow.default)
    }

    /// An interval the user deliberately switched off must stay off.
    ///
    /// The encoder omits the key entirely for `nil`, so "off" and "absent" are the same bytes on
    /// disk. Giving the intervals a default the way a genuinely new field gets one would turn
    /// refreshing back on for everyone who had turned it off — which is why they are the one group
    /// of fields in this type that falls back to `nil` rather than to `RefreshSettings()`.
    @Test("An interval that was switched off stays off through a decode")
    func switchedOffIntervalsStayOff() throws {
        var settings = RefreshSettings()
        settings.mastodonSeconds = nil
        settings.freshRSSSeconds = nil

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(RefreshSettings.self, from: encoded)

        #expect(decoded.mastodonSeconds == nil)
        #expect(decoded.freshRSSSeconds == nil)
        #expect(decoded.isEnabled(.mastodonFeeds) == false)
        // While the ones that were left alone are untouched.
        #expect(decoded.syncStateSeconds == RefreshSettings().syncStateSeconds)
    }
}
