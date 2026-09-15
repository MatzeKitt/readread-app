import Foundation
import Testing
@testable import ReadReadModel

/// Settings are decoded from a blob written by an older build of the app, so adding a field must
/// never cost the reader the preferences they already set.
@Suite("Reading settings compatibility")
struct ReadingSettingsMigrationTests {

    /// Exactly what `ReadingSettingsStore` wrote before text sizes existed.
    private let legacy = """
    {"archivesReadLaterContent":false,"showsLateArrivalBadges":false,"loadsMastodonThreads":true}
    """

    @Test("A blob written before text sizes existed keeps its own values")
    func legacyBlobSurvives() throws {
        let settings = try JSONDecoder().decode(ReadingSettings.self, from: Data(legacy.utf8))

        // The point of the test: these were deliberately changed by the user and must come back.
        #expect(settings.archivesReadLaterContent == false)
        #expect(settings.showsLateArrivalBadges == false)
        #expect(settings.loadsMastodonThreads == true)

        // And the new fields arrive at their defaults rather than failing the decode.
        #expect(settings.listHeadingScale == .standard)
        #expect(settings.listBodyScale == .standard)
        #expect(settings.contentScale == .standard)
        #expect(settings.contentLineHeight == ReadingSettings.defaultLineHeight)
        #expect(settings.opensLinksInApp == true)
    }

    /// The setting the reader is most likely to have deliberately turned *off*, in a blob written
    /// before it existed — so its default has to be the on state and its absence must not reset
    /// anything around it.
    @Test("Choosing the browser survives a round trip")
    func linkDestinationRoundTrips() throws {
        var settings = ReadingSettings()
        settings.opensLinksInApp = false
        settings.showsLateArrivalBadges = false

        let decoded = try JSONDecoder().decode(
            ReadingSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        #expect(decoded.opensLinksInApp == false)
        #expect(decoded.showsLateArrivalBadges == false)
        #expect(decoded == settings)
    }

    @Test("Links open in the app unless someone says otherwise")
    func linksOpenInAppByDefault() {
        #expect(ReadingSettings.default.opensLinksInApp)
    }

    /// Filtered Items is a diagnostic list, not a backlog. A count beside it would read like every
    /// other sidebar count — items waiting to be read — so it is opt-in, and a settings blob written
    /// before the option existed must not arrive with it switched on.
    @Test("Filtered Items carries no count unless asked")
    func filteredBadgeIsOffByDefault() throws {
        #expect(ReadingSettings.default.showsFilteredItemsBadge == false)

        let legacyBlob = try JSONDecoder().decode(ReadingSettings.self, from: Data(legacy.utf8))
        #expect(legacyBlob.showsFilteredItemsBadge == false)
    }

    @Test("Asking for the count survives a round trip")
    func filteredBadgeRoundTrips() throws {
        var settings = ReadingSettings()
        settings.showsFilteredItemsBadge = true

        let decoded = try JSONDecoder().decode(
            ReadingSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        #expect(decoded.showsFilteredItemsBadge)
    }

    @Test("An empty object is all defaults, not a failure")
    func emptyObject() throws {
        let settings = try JSONDecoder().decode(ReadingSettings.self, from: Data("{}".utf8))
        #expect(settings == .default)
    }

    @Test("Text sizes round-trip through the store")
    func roundTrip() throws {
        var settings = ReadingSettings()
        settings.listHeadingScale = .extraLarge
        settings.listBodyScale = .small
        settings.contentScale = .large
        settings.contentLineHeight = 1.8

        let decoded = try JSONDecoder().decode(
            ReadingSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test("A line height outside the usable range is corrected rather than honoured")
    func lineHeightIsClamped() throws {
        // 0 collapses every line onto the last and 40 scrolls a paragraph off the screen; both
        // reach a stylesheet and a layout engine that will do exactly as they are told.
        #expect(ReadingSettings(contentLineHeight: 0).contentLineHeight == ReadingSettings.lineHeightRange.lowerBound)
        #expect(ReadingSettings(contentLineHeight: 40).contentLineHeight == ReadingSettings.lineHeightRange.upperBound)
        #expect(ReadingSettings(contentLineHeight: .nan).contentLineHeight == ReadingSettings.defaultLineHeight)

        // Including when it arrives from a stored blob someone has edited by hand.
        let decoded = try JSONDecoder().decode(
            ReadingSettings.self,
            from: Data(#"{"contentLineHeight":99}"#.utf8)
        )
        #expect(decoded.contentLineHeight == ReadingSettings.lineHeightRange.upperBound)
    }

    @Test("The default leading is the documented one")
    func defaultLeading() {
        #expect(ReadingSettings.defaultLineHeight == 1.5)
        #expect(ReadingSettings().contentLineHeight == 1.5)
    }

    @Test("Standard is exactly the size the app drew before the setting existed")
    func standardIsNeutral() {
        #expect(TextScale.standard.multiplier == 1.0)
    }

    @Test("The steps are ordered, and none of them is drastic")
    func stepsAreOrdered() {
        let multipliers = TextScale.allCases.map(\.multiplier)
        #expect(multipliers == multipliers.sorted())
        // A heading must not be able to come out smaller than the body text under it, which is
        // what an unbounded range would allow.
        #expect(multipliers.first! > 0.75)
        #expect(multipliers.last! < 1.5)
    }
}
