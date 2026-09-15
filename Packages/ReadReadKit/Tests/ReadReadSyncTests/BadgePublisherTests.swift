import Foundation
import ReadReadModel
import Testing

@testable import ReadReadSync

/// The gating is the whole feature. Every case here is a badge that would otherwise show a number
/// the store does not actually support — and a badge is believed, because it is looked at when the
/// app is closed and there is nothing on screen to contradict it.
@Suite("BadgePublisher")
struct BadgePublisherTests {

    /// Captures what was written to the platform badge.
    private actor Recorder {
        private(set) var writes: [Int] = []
        private var shouldThrow = false

        nonisolated func setter() -> BadgePublisher.Setter {
            { [weak self] count in
                try await self?.record(count)
            }
        }

        private func record(_ count: Int) throws {
            if shouldThrow { throw RecorderError.refused }
            writes.append(count)
        }

        func setThrowing(_ throwing: Bool) { shouldThrow = throwing }
        var writeCount: Int { writes.count }
        var last: Int? { writes.last }

        enum RecorderError: Error { case refused }
    }

    private func makePublisher() -> (BadgePublisher, Recorder) {
        let recorder = Recorder()
        return (BadgePublisher(setBadge: recorder.setter()), recorder)
    }

    private let consistent = RefreshRunReport(ingestComplete: true, syncSucceeded: true)

    // MARK: - Position changes

    @Test("Reading updates the badge without waiting for a refresh")
    func positionChangePublishes() async throws {
        let (publisher, recorder) = makePublisher()
        await publisher.publish(count: 40, report: consistent)

        #expect(await publisher.publishPositionChange(count: 12))
        #expect(await publisher.publishPositionChange(count: 0))

        // The number on the icon follows the reader, instead of standing at 40 until whichever
        // feed refresh happens to run next.
        #expect(await recorder.writes == [40, 12, 0])
        #expect(await publisher.lastPublishedCount == 0)
    }

    @Test("A position change before any consistent run is refused")
    func positionChangeNeedsABaseline() async throws {
        let (publisher, recorder) = makePublisher()

        #expect(await !publisher.publishPositionChange(count: 7))
        #expect(await recorder.writeCount == 0)

        // An interrupted run establishes no item set either, so scrolling still must not publish:
        // the count would be a position against a partial half of the store.
        await publisher.publish(
            count: 7,
            report: RefreshRunReport(ingestComplete: false, syncSucceeded: true)
        )
        #expect(await !publisher.publishPositionChange(count: 3))
        #expect(await recorder.writeCount == 0)
    }

    @Test("An unchanged count is not rewritten")
    func positionChangeSkipsRedundantWrites() async throws {
        let (publisher, recorder) = makePublisher()
        await publisher.publish(count: 5, report: consistent)

        // Scrolling within one screen settles repeatedly without the count moving; each of those
        // would otherwise be a cross-process call for no effect.
        #expect(await !publisher.publishPositionChange(count: 5))
        #expect(await recorder.writes == [5])
    }

    @Test("A refused write leaves the last good value in place")
    func positionChangeSurvivesRefusal() async throws {
        let (publisher, recorder) = makePublisher()
        await publisher.publish(count: 9, report: consistent)
        await recorder.setThrowing(true)

        #expect(await !publisher.publishPositionChange(count: 1))
        #expect(await publisher.lastPublishedCount == 9)
    }

    // MARK: - The gate

    @Test("A consistent run publishes")
    func consistentRunPublishes() async {
        let (publisher, recorder) = makePublisher()

        #expect(await publisher.publish(count: 42, report: consistent))

        #expect(await recorder.writes == [42])
        #expect(await publisher.lastPublishedCount == 42)
    }

    /// The failure that matters most. A run cut short by the background budget has counted only
    /// part of what arrived, so its number is *lower* than the truth — the badge would say "3"
    /// while forty items wait, and the user would stop looking.
    @Test("An incomplete ingest publishes nothing")
    func incompleteIngestWithholds() async {
        let (publisher, recorder) = makePublisher()

        let published = await publisher.publish(
            count: 3,
            report: RefreshRunReport(ingestComplete: false, syncSucceeded: true)
        )

        #expect(published == false)
        #expect(await recorder.writes.isEmpty)
        #expect(await publisher.withheldCount == 3)
    }

    /// The badge is a function of items *and* position. Fresh items against a stale marker
    /// over-counts; the two come from different servers, so both have to have landed.
    @Test("A failed sync publishes nothing")
    func failedSyncWithholds() async {
        let (publisher, recorder) = makePublisher()

        let published = await publisher.publish(
            count: 99,
            report: RefreshRunReport(ingestComplete: true, syncSucceeded: false)
        )

        #expect(published == false)
        #expect(await recorder.writes.isEmpty)
    }

    /// A cycle that only refreshed positions has not established a new item count, so it must not
    /// publish one — the items it would be counting are however stale the last ingest left them.
    @Test("A cycle that ingested nothing publishes nothing")
    func syncOnlyCycleWithholds() async {
        let (publisher, _) = makePublisher()

        let published = await publisher.publish(
            count: 7,
            report: RefreshRunReport(ingestComplete: true, syncSucceeded: true, didIngestItems: false)
        )

        #expect(published == false)
    }

    /// The point of withholding rather than writing zero: an interrupted run must leave the last
    /// trustworthy number in place. Blanking it would read as "all caught up", which is the most
    /// misleading thing the badge could say.
    @Test("A withheld run leaves the previous value untouched")
    func withheldRunKeepsPreviousValue() async {
        let (publisher, recorder) = makePublisher()

        await publisher.publish(count: 42, report: consistent)
        await publisher.publish(count: 3, report: RefreshRunReport(ingestComplete: false, syncSucceeded: true))

        #expect(await recorder.writes == [42])
        #expect(await publisher.lastPublishedCount == 42)
    }

    // MARK: - Flicker

    /// Gating also removes the climb: without it the count steps 3 → 17 → 42 as pages land.
    @Test("Only the final count of a multi-page cycle is written")
    func onlyFinalCountIsWritten() async {
        let (publisher, recorder) = makePublisher()
        let partial = RefreshRunReport(ingestComplete: false, syncSucceeded: true)

        for count in [3, 17, 30] {
            await publisher.publish(count: count, report: partial)
        }
        await publisher.publish(count: 42, report: consistent)

        #expect(await recorder.writes == [42])
    }

    @Test("An unchanged count is not rewritten")
    func unchangedCountIsNotRewritten() async {
        let (publisher, recorder) = makePublisher()

        #expect(await publisher.publish(count: 5, report: consistent))
        #expect(await publisher.publish(count: 5, report: consistent) == false)

        #expect(await recorder.writeCount == 1)
    }

    @Test("A changed count is written again")
    func changedCountIsWritten() async {
        let (publisher, recorder) = makePublisher()

        await publisher.publish(count: 5, report: consistent)
        await publisher.publish(count: 0, report: consistent)
        await publisher.publish(count: 12, report: consistent)

        #expect(await recorder.writes == [5, 0, 12])
    }

    /// Reaching zero has to be published, or a caught-up user keeps a stale badge forever.
    @Test("Zero is publishable")
    func zeroIsPublishable() async {
        let (publisher, recorder) = makePublisher()

        await publisher.publish(count: 7, report: consistent)
        #expect(await publisher.publish(count: 0, report: consistent))

        #expect(await recorder.last == 0)
    }

    // MARK: - Withheld diagnostics

    @Test("A subsequent successful publish clears the withheld value")
    func successClearsWithheldValue() async {
        let (publisher, _) = makePublisher()

        await publisher.publish(count: 3, report: RefreshRunReport(ingestComplete: false, syncSucceeded: true))
        #expect(await publisher.withheldCount == 3)

        await publisher.publish(count: 42, report: consistent)
        #expect(await publisher.withheldCount == nil)
    }

    // MARK: - Platform refusal

    /// Badge authorisation being refused is an ordinary user choice on iOS, not an error worth
    /// surfacing — but it must not be mistaken for a successful publish either.
    @Test("A refused badge write reports failure and does not record a value")
    func refusedWriteIsNotRecorded() async {
        let (publisher, recorder) = makePublisher()
        await recorder.setThrowing(true)

        #expect(await publisher.publish(count: 9, report: consistent) == false)
        #expect(await publisher.lastPublishedCount == nil)

        // And once permission is granted, the same count still publishes — it was never recorded
        // as already written.
        await recorder.setThrowing(false)
        #expect(await publisher.publish(count: 9, report: consistent))
    }

    @Test("Clearing writes zero")
    func clearWritesZero() async {
        let (publisher, recorder) = makePublisher()

        await publisher.publish(count: 7, report: consistent)
        await publisher.clear()

        #expect(await recorder.writes == [7, 0])
        #expect(await publisher.lastPublishedCount == 0)
    }

    // MARK: - Report

    @Test("Consistency requires all three conditions", arguments: [
        (true, true, true, true),
        (false, true, true, false),
        (true, false, true, false),
        (true, true, false, false),
        (false, false, false, false),
    ])
    func consistencyRequiresAllConditions(
        ingest: Bool,
        sync: Bool,
        ingestedItems: Bool,
        expected: Bool
    ) {
        let report = RefreshRunReport(
            ingestComplete: ingest,
            syncSucceeded: sync,
            didIngestItems: ingestedItems
        )

        #expect(report.isConsistent == expected)
    }
}
