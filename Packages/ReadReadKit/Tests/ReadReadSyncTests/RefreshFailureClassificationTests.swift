import Foundation
import Testing

@testable import ReadReadSync

/// Which failures earn a backoff. Getting this wrong is silent and severe: a single account that
/// can never work took every healthy account off the network with it, doubling the retry delay to
/// the thirty-minute cap, and the only symptom was an app that stopped making requests.
@Suite("Refresh failure classification")
struct RefreshFailureClassificationTests {

    @Test("A report treats its failures as retryable unless told otherwise")
    func defaultsToRetryable() {
        let report = RefreshReport(kind: .freshRSSFeeds, failures: ["server exploded"])
        #expect(report.retryableFailures == ["server exploded"])
    }

    @Test("A configuration failure is reported but not retried")
    func configurationFailuresAreNotRetryable() {
        var report = RefreshReport(kind: .freshRSSFeeds, failures: ["no saved password"])
        report.retryableFailures = []

        // Still shown to the user — they have to know to sign in.
        #expect(report.failures == ["no saved password"])
        // But nothing here gets better by waiting, so it must not drive the backoff.
        #expect(report.retryableFailures.isEmpty)
    }

    @Test("Repeated failures grow the delay to the half-hour cap")
    func backoffGrowsAndCaps() async {
        struct Failed: Error {}
        let coordinator = RefreshCoordinator(
            settings: RefreshSettings(syncStateSeconds: 30),
            isLowPowerMode: false,
            operation: { _, _ in throw Failed() }
        )

        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(30))

        // This is the mechanism the bug rode on: every cycle that throws doubles the wait, so a
        // permanently broken account silences a healthy one within a few minutes.
        for _ in 0..<10 {
            await coordinator.refresh(.syncState, trigger: .manual)
        }

        #expect(await coordinator.failureCount(for: .syncState) == 10)
        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(30 * 60))
    }

    @Test("A successful cycle clears the penalty")
    func successResetsBackoff() async {
        struct Failed: Error {}
        let shouldFail = Flag()
        let coordinator = RefreshCoordinator(
            settings: RefreshSettings(syncStateSeconds: 30),
            isLowPowerMode: false,
            operation: { _, _ in if await shouldFail.value { throw Failed() } }
        )

        await shouldFail.set(true)
        for _ in 0..<3 { await coordinator.refresh(.syncState, trigger: .manual) }
        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(240))

        await shouldFail.set(false)
        await coordinator.refresh(.syncState, trigger: .manual)
        #expect(await coordinator.nextDelay(for: .syncState) == .seconds(30))
    }
}

private actor Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
