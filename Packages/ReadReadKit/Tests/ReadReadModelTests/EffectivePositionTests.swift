import Foundation
import Testing

@testable import ReadReadModel

/// The reduction is what turns several devices' rows into the one position the UI shows. Getting
/// it wrong does not crash anything — it quietly puts the reader somewhere they never were.
@Suite("EffectivePosition reduction")
struct EffectivePositionTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func mark(
        _ deviceID: String,
        at millis: Int64,
        writtenAt seconds: TimeInterval
    ) -> (deviceID: String, markSortKey: SortKey, updatedAt: Date) {
        (
            deviceID: deviceID,
            markSortKey: SortKey(millis: millis, id: "i"),
            updatedAt: epoch.addingTimeInterval(seconds)
        )
    }

    @Test("No rows means nothing has a position")
    func emptyReducesToUnread() {
        let position = EffectivePosition.reduce([], scope: .all)

        #expect(position.markSortKey == .distantPast)
        #expect(position.scope == .all)
    }

    @Test("A single row is the position")
    func singleRowWins() {
        let position = EffectivePosition.reduce([mark("mac", at: 5_000, writtenAt: 10)], scope: .all)

        #expect(position.markSortKey.millis == 5_000)
    }

    /// The rule, and the one that changed. A position is where the reader is, so the newest report
    /// of it is the truth — *even when it is further back*, which is exactly what happens when they
    /// scroll down. The earlier design took the furthest position instead, which pinned the count
    /// to whichever device had scrolled deepest and could never let it rise again.
    @Test("The most recently written row wins, even when its position is further back")
    func mostRecentWinsOverFurthest() {
        let position = EffectivePosition.reduce([
            mark("mac", at: 9_000, writtenAt: 10),
            mark("iphone", at: 2_000, writtenAt: 20),
        ], scope: .all)

        #expect(position.markSortKey.millis == 2_000)
    }

    @Test("A device that moves again reclaims the position")
    func laterWriteReclaims() {
        let position = EffectivePosition.reduce([
            mark("mac", at: 9_000, writtenAt: 30),
            mark("iphone", at: 2_000, writtenAt: 20),
        ], scope: .all)

        #expect(position.markSortKey.millis == 9_000)
    }

    /// Rows arrive from a fetch in no guaranteed order, and from sync in revision order. The result
    /// has to be the same either way, or two devices holding identical data would disagree.
    @Test("The result does not depend on the order rows are fed in")
    func reductionIsOrderIndependent() {
        let marks = [
            mark("a", at: 1_000, writtenAt: 30),
            mark("b", at: 9_000, writtenAt: 10),
            mark("c", at: 5_000, writtenAt: 20),
        ]

        let forward = EffectivePosition.reduce(marks, scope: .all)
        let backward = EffectivePosition.reduce(marks.reversed(), scope: .all)

        #expect(forward == backward)
        #expect(forward.markSortKey.millis == 1_000)
    }

    /// Two devices can legitimately share a timestamp — a coarse clock, or a restore that stamped
    /// several rows at once. Breaking the tie on something stable keeps the result deterministic.
    @Test("A tie on time is broken deterministically")
    func tieIsBrokenDeterministically() {
        let marks = [
            mark("aaa", at: 1_000, writtenAt: 10),
            mark("zzz", at: 9_000, writtenAt: 10),
        ]

        #expect(EffectivePosition.reduce(marks, scope: .all).markSortKey.millis == 9_000)
        #expect(EffectivePosition.reduce(marks.reversed(), scope: .all).markSortKey.millis == 9_000)
    }

    @Test("The scope is carried through")
    func scopeIsCarried() {
        let position = EffectivePosition.reduce([mark("mac", at: 1, writtenAt: 1)], scope: .readLater)

        #expect(position.scope == .readLater)
    }

    @Test("The winning row's timestamp is reported")
    func winningTimestampIsReported() {
        let position = EffectivePosition.reduce([
            mark("mac", at: 9_000, writtenAt: 10),
            mark("iphone", at: 2_000, writtenAt: 20),
        ], scope: .all)

        #expect(position.updatedAt == epoch.addingTimeInterval(20))
    }
}
