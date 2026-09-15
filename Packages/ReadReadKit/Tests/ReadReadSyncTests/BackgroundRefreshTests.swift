import Foundation
import Testing

@testable import ReadReadSync

/// Covers the diary rather than the scheduler.
///
/// `BGTaskScheduler` cannot be driven from a unit test — there is no seam and no simulator support
/// — so what is tested here is the part that carries a claim the settings screen then makes to the
/// reader: whether a request was accepted, and when a run last happened. Getting that wrong is
/// worse than not showing it, because it would answer "is background refresh working" incorrectly.
// Serialised because the defaults seam is process-wide: run in parallel, one test's cleanup
// restores the standard suite underneath another test's reads, which fails in a way that looks
// like the diary not persisting at all.
@Suite("Background refresh diagnostics", .serialized)
struct BackgroundRefreshTests {

    /// A defaults suite of its own, so a test run never writes the app's real diary.
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let name = "ReadReadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let previous = BackgroundRefresh.defaults
        BackgroundRefresh.defaults = defaults
        defer {
            BackgroundRefresh.defaults = previous
            defaults.removePersistentDomain(forName: name)
        }
        body(defaults)
    }

    @Test("Nothing has happened yet on a fresh install")
    func startsEmpty() {
        withIsolatedDefaults { _ in
            let diagnostics = BackgroundRefresh.diagnostics
            #expect(diagnostics.lastRunAt == nil)
            #expect(diagnostics.runCount == 0)
            #expect(diagnostics.isRequestQueued == false)
        }
    }

    @Test("A run is recorded with its time and counted")
    func recordsRuns() {
        withIsolatedDefaults { _ in
            let first = Date(timeIntervalSince1970: 1_000)
            BackgroundRefresh.recordRun(at: first)
            #expect(BackgroundRefresh.diagnostics.lastRunAt == first)
            #expect(BackgroundRefresh.diagnostics.runCount == 1)

            let second = Date(timeIntervalSince1970: 2_000)
            BackgroundRefresh.recordRun(at: second)
            #expect(BackgroundRefresh.diagnostics.lastRunAt == second)
            #expect(BackgroundRefresh.diagnostics.runCount == 2)
        }
    }

    /// The case worth surfacing: a declined request and a request the system has simply not chosen
    /// to run yet look identical from inside the app, and only one of them has a fix the reader can
    /// apply.
    @Test("A refusal is remembered, and a later acceptance clears it")
    func recordsWhetherARequestIsQueued() {
        withIsolatedDefaults { _ in
            BackgroundRefresh.recordSchedule(accepted: false)
            #expect(BackgroundRefresh.diagnostics.isRequestQueued == false)
            #expect(BackgroundRefresh.diagnostics.lastScheduledAt == nil)

            let when = Date(timeIntervalSince1970: 5_000)
            BackgroundRefresh.recordSchedule(accepted: true, at: when)
            #expect(BackgroundRefresh.diagnostics.isRequestQueued)
            #expect(BackgroundRefresh.diagnostics.lastScheduledAt == when)
        }
    }
}
