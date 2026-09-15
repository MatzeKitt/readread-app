import Foundation
import Testing

@testable import ReadReadUI

/// Which way round a relative timestamp reads.
///
/// Worth a suite of its own because the failure is invisible in exactly the place you would look
/// for it. Every row in a timeline is in the past, so a reversed timestamp does not produce one odd
/// entry among correct ones — it produces a whole list that is uniformly, plausibly wrong, and
/// "55m" and "in 55m" are one word apart at caption size. The shipping version of this said every
/// post had been published in the future.
@Suite("RelativeTimestamp")
struct RelativeTimestampTests {

    /// Fixed, because "ago" is the assertion and a translated build would be asserting nothing.
    private let locale = Locale(identifier: "en_US")

    private func text(
        publishedAt date: Date,
        asOf now: Date,
        unitsStyle: Date.RelativeFormatStyle.UnitsStyle = .abbreviated
    ) -> String {
        RelativeTimestamp.style(for: date, unitsStyle: unitsStyle).locale(locale).format(now)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    @Test("An item published an hour ago reads as the past")
    func pastItemReadsAsPast() {
        let label = text(publishedAt: now.addingTimeInterval(-3_300), asOf: now)

        #expect(label.contains("55"))
        #expect(label.hasSuffix("ago"))
    }

    /// The spoken label is built from the same style and would have been reversed with it — and
    /// VoiceOver announcing "in 55 minutes" is the version of this bug nobody can see at all.
    @Test("The spoken label reads as the past too")
    func spokenLabelReadsAsPast() {
        let label = text(publishedAt: now.addingTimeInterval(-7_200), asOf: now, unitsStyle: .wide)

        #expect(label == "2 hours ago")
    }

    /// Not hypothetical: a feed with a wrong clock, or a post scheduled ahead, genuinely arrives
    /// dated in the future, and it has to be distinguishable from everything else in the list.
    @Test("An item dated in the future still reads as the future")
    func futureItemReadsAsFuture() {
        let label = text(publishedAt: now.addingTimeInterval(3_300), asOf: now)

        #expect(label.contains("55"))
        #expect(!label.hasSuffix("ago"))
    }

    @Test("A moment old is a moment ago, not a moment away")
    func secondsOldReadsAsPast() {
        #expect(text(publishedAt: now.addingTimeInterval(-5), asOf: now, unitsStyle: .wide) == "5 seconds ago")
    }

    /// The rows drew `Date.RelativeFormatStyle` before they learned to age, and nobody asked for
    /// the timeline to start wording its timestamps differently. Both styles are asked the same
    /// question here — the plain one can only measure against the present, so the present is what
    /// both are given.
    @Test("Ageing did not change what a timestamp says")
    func matchesTheStyleItReplaced() {
        for unitsStyle in [Date.RelativeFormatStyle.UnitsStyle.abbreviated, .wide] {
            for locale in [Locale(identifier: "en_US"), Locale(identifier: "de_DE")] {
                for seconds in [5.0, 90.0, 3_300.0, 7_200.0, 259_200.0, 3_456_000.0] {
                    // The plain style has no anchor to set, so "now" has to be the real one.
                    let now = Date.now
                    let published = now.addingTimeInterval(-seconds)

                    let aged = RelativeTimestamp.style(for: published, unitsStyle: unitsStyle)
                        .locale(locale)
                        .format(now)
                    let before = Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: unitsStyle)
                        .locale(locale)
                        .format(published)

                    #expect(aged == before, "\(locale.identifier), \(seconds)s")
                }
            }
        }
    }
}
