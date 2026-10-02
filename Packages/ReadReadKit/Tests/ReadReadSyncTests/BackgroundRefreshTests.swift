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

    /// The reason is what the settings screen words its advice from, so a stale one would send the
    /// reader to fix a switch that is already on.
    @Test("A refusal keeps its reason until a request is accepted")
    func keepsTheReasonForARefusal() {
        withIsolatedDefaults { _ in
            BackgroundRefresh.recordRefusal(.unavailable, trigger: .launch, detail: "BGTaskSchedulerErrorDomain 1")
            var diagnostics = BackgroundRefresh.diagnostics
            #expect(diagnostics.isRequestQueued == false)
            #expect(diagnostics.refusal == .unavailable)
            #expect(diagnostics.refusalDetail == "BGTaskSchedulerErrorDomain 1")

            BackgroundRefresh.recordSchedule(accepted: true)
            diagnostics = BackgroundRefresh.diagnostics
            #expect(diagnostics.refusal == nil)
            #expect(diagnostics.refusalDetail == nil)
        }
    }

    @Test("A later refusal without detail does not inherit the earlier one's")
    func refusalDetailIsNotInherited() {
        withIsolatedDefaults { _ in
            BackgroundRefresh.recordRefusal(.unavailable, trigger: .launch, detail: "old")
            BackgroundRefresh.recordRefusal(.cadencesOff, trigger: .settingsChanged)
            #expect(BackgroundRefresh.diagnostics.refusal == .cadencesOff)
            #expect(BackgroundRefresh.diagnostics.refusalDetail == nil)
        }
    }

    @Test("The log keeps events newest first, with who asked")
    func logsEventsNewestFirst() {
        withIsolatedDefaults { _ in
            let start = Date(timeIntervalSince1970: 1_000)
            BackgroundRefresh.recordRefusal(.unavailable, trigger: .launch, at: start)
            BackgroundRefresh.recordRun(at: start.addingTimeInterval(60), detail: "cold launch")
            BackgroundRefresh.recordRunEnded(
                startedAt: start.addingTimeInterval(60),
                expired: true,
                at: start.addingTimeInterval(90)
            )

            let log = BackgroundRefresh.diagnostics.log
            #expect(log.map(\.event) == [.runExpired, .runStarted, .declined])
            #expect(log.last?.trigger == .launch)
            #expect(log.last?.detail == "unavailable")
            #expect(log[1].detail == "cold launch")
            #expect(log.first?.detail == "After 30.0 s")
        }
    }

    /// The case from a new phone: the bundle identifier gained a team suffix the permitted list
    /// never saw, and a derived identifier asked for something undeclared.
    @Test("The identifier is the declared one, whatever the bundle identifier says")
    func identifierFollowsTheDeclaration() {
        #expect(BackgroundRefresh.identifier(
            permitted: ["com.kittmedia.ReadRead.refresh"],
            bundleIdentifier: "com.kittmedia.ReadRead.QR2CW5GWB2"
        ) == "com.kittmedia.ReadRead.refresh")
        #expect(BackgroundRefresh.identifier(
            permitted: ["com.example.other", "com.kittmedia.ReadRead.refresh"],
            bundleIdentifier: nil
        ) == "com.kittmedia.ReadRead.refresh")
        #expect(BackgroundRefresh.identifier(
            permitted: nil,
            bundleIdentifier: "com.kittmedia.ReadRead"
        ) == "com.kittmedia.ReadRead.refresh")
    }

    @Test("The log drops its oldest entries past the limit")
    func logIsCapped() {
        withIsolatedDefaults { _ in
            for index in 0..<(BackgroundRefresh.logLimit + 5) {
                BackgroundRefresh.log(.scheduled, detail: "\(index)")
            }
            let log = BackgroundRefresh.diagnostics.log
            #expect(log.count == BackgroundRefresh.logLimit)
            #expect(log.first?.detail == "\(BackgroundRefresh.logLimit + 4)")
            #expect(log.last?.detail == "5")
        }
    }
}
