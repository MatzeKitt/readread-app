import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The rules that keep the timeline from moving under the reader and keep positions honest.
///
/// None of these need a list: the list only carries out what these decide.
@MainActor
@Suite("Timeline scrolling")
struct TimelineScrollingTests {

    private let context: ModelContext

    init() throws {
        context = ModelContext(try ReadReadStore.inMemoryContainer())
    }

    /// Rows for `millis`, newest first, named `item-<millis>`.
    private func snapshot(_ millis: [Int64], generation: Int = 1) -> TimelineSnapshot {
        let rows = millis.sorted(by: >).map { millis in
            let id = "item-\(millis)"
            let key = SortKey(millis: millis, id: id)
            let item = CachedItem(
                id: id,
                sourceID: "feed",
                accountID: UUID(),
                folderName: nil,
                kind: .article,
                title: id,
                publishedAt: Date(millisecondsSinceEpoch: millis),
                sortKey: key,
                ingestKey: key
            )
            context.insert(item)
            return TimelineRow(id: id, sortKey: key, persistentID: item.persistentModelID)
        }
        return TimelineSnapshot(rows: rows, generation: generation)
    }

    private func key(_ millis: Int64) -> SortKey {
        SortKey(millis: millis, id: "item-\(millis)")
    }

    // MARK: - Snapshot

    @Test("The fold row for a mark is the marked item, its index the count above it")
    func foldRowExact() {
        let snap = snapshot([10, 20, 30, 40, 50])
        // Newest first: 50, 40, 30, 20, 10.
        #expect(snap.foldRow(for: key(30)) == 2)
        #expect(snap.foldRow(for: key(50)) == 0)
        #expect(snap.foldRow(for: key(10)) == 4)
    }

    @Test("A mark naming a missing item lands on the newest item older than it")
    func foldRowMissing() {
        let snap = snapshot([10, 20, 40, 50])
        #expect(snap.foldRow(for: key(30)) == 2)
    }

    @Test("Sentinels land at the ends, and an empty snapshot has no fold")
    func foldRowSentinels() {
        let snap = snapshot([10, 20, 30])
        #expect(snap.foldRow(for: .distantPast) == 2)
        #expect(snap.foldRow(for: .distantFuture) == 0)
        #expect(TimelineSnapshot.empty.foldRow(for: key(10)) == nil)
    }

    // MARK: - Anchor

    @Test("Arrivals above keep the anchor, now further down the rows")
    func anchorKeptThroughArrivals() throws {
        let old = snapshot([10, 20, 30])
        let new = snapshot([10, 20, 30, 40, 50], generation: 2)
        let anchor = try #require(old.rows.first { $0.id == "item-20" })

        let resolution = AnchorResolver.resolve(anchor: anchor, old: old, new: new)
        #expect(resolution == .init(row: 3, isSameItem: true))
    }

    @Test("A pruned anchor hands over to its nearest older neighbour")
    func anchorPrunedGoesOlder() throws {
        let old = snapshot([10, 20, 30, 40])
        let new = snapshot([10, 40], generation: 2)
        let anchor = try #require(old.rows.first { $0.id == "item-30" })

        // 20 is gone too, so the next older survivor is 10 — never 40, which is unread.
        let resolution = AnchorResolver.resolve(anchor: anchor, old: old, new: new)
        #expect(resolution == .init(row: 1, isSameItem: false))
    }

    @Test("With nothing older left, the nearest newer survivor takes over")
    func anchorPrunedGoesNewer() throws {
        let old = snapshot([10, 20, 30])
        let new = snapshot([30], generation: 2)
        let anchor = try #require(old.rows.first { $0.id == "item-10" })

        #expect(AnchorResolver.resolve(anchor: anchor, old: old, new: new) == .init(row: 0, isSameItem: false))
    }

    @Test("When nothing visible survives, the anchor's time decides — not the top of the list")
    func anchorAllReplaced() throws {
        let old = snapshot([20, 30])
        let new = snapshot([5, 25, 60, 70], generation: 2)
        let anchor = try #require(old.rows.first { $0.id == "item-30" })

        // 70, 60, 25, 5: the newest item not newer than 30 is 25, at row 2.
        #expect(AnchorResolver.resolve(anchor: anchor, old: old, new: new) == .init(row: 2, isSameItem: false))
    }

    @Test("An empty new snapshot has nowhere to put the anchor")
    func anchorIntoEmpty() throws {
        let old = snapshot([10])
        #expect(AnchorResolver.resolve(anchor: old.rows[0], old: old, new: .empty) == nil)
    }

    // MARK: - Gate

    private func shownGate(at start: ContinuousClock.Instant) -> ViewportGate {
        var gate = ViewportGate()
        gate.hasViewport = true
        gate.positioned(at: start)
        return gate
    }

    @Test("Nothing programmatic happens while the list is being positioned")
    func gatePositioning() {
        var gate = ViewportGate()
        gate.hasViewport = true
        let now = ContinuousClock.now
        #expect(!gate.isQuiet(at: now + .seconds(5)))
        let began = gate.beginProgrammatic(at: now + .seconds(5))
        #expect(!began)
        #expect(!gate.mayReadFold)
    }

    @Test("Nothing programmatic happens while the reader scrolls, or right after")
    func gateWaitsForQuiet() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)

        gate.userBegan()
        let duringScroll = gate.beginProgrammatic(at: start + .seconds(3))
        #expect(!duringScroll)

        let recorded = gate.userEnded(at: start + .seconds(3))
        #expect(recorded)
        let tooSoon = gate.beginProgrammatic(at: start + .milliseconds(3_200))
        #expect(!tooSoon)
        let afterQuiet = gate.beginProgrammatic(at: start + .milliseconds(3_600))
        #expect(afterQuiet)
        gate.endProgrammatic()
        #expect(gate.phase == .idle)
    }

    @Test("Only the end of a reader's interaction asks for the fold to be recorded")
    func gateOnlyUserSettlesRecord() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)

        // A programmatic move ending is not a settle.
        let began = gate.beginProgrammatic(at: start + .seconds(1))
        #expect(began)
        gate.endProgrammatic()
        let afterProgrammatic = gate.userEnded(at: start + .seconds(2))
        #expect(!afterProgrammatic)

        gate.userBegan()
        let afterReader = gate.userEnded(at: start + .seconds(3))
        #expect(afterReader)
    }

    @Test("A zero-sized list records nothing and is never quiet")
    func gateWithoutViewport() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)
        gate.hasViewport = false

        gate.userBegan()
        let recorded = gate.userEnded(at: start + .seconds(1))
        #expect(!recorded)
        #expect(!gate.isQuiet(at: start + .seconds(5)))
    }

    @Test("The reader taking hold cancels a programmatic move in progress")
    func gateReaderWins() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)
        let began = gate.beginProgrammatic(at: start + .seconds(1))
        #expect(began)
        gate.userBegan()
        #expect(gate.phase == .interacting)
        gate.endProgrammatic()
        #expect(gate.phase == .interacting)
    }

    @Test("A move the reader asked for skips the quiet period but still records nothing")
    func gateRequestedMove() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)
        gate.userBegan()
        _ = gate.userEnded(at: start + .seconds(1))

        let began = gate.beginRequested()
        #expect(began)
        gate.endProgrammatic()
        let recorded = gate.userEnded(at: start + .seconds(2))
        #expect(!recorded)
    }

    @Test("Nothing programmatic happens in the background")
    func gateInactive() {
        let start = ContinuousClock.now
        var gate = shownGate(at: start)
        gate.isAppActive = false
        #expect(!gate.isQuiet(at: start + .seconds(5)))
    }

    // MARK: - Writing

    private let me = "device-me"
    private let other = "device-other"

    @Test("Nothing is written before this session has heard the other devices")
    func writeWaitsForMerge() {
        let settle = PositionWritePolicy.Settle(itemID: "item-20", sortKey: key(20), at: .now)
        #expect(!PositionWritePolicy.shouldWrite(.init(
            settle: settle, stored: nil, arePositionsMerged: false, deviceID: me
        )))
        #expect(PositionWritePolicy.shouldWrite(.init(
            settle: settle, stored: nil, arePositionsMerged: true, deviceID: me
        )))
    }

    @Test("Settling on this device's own position again writes nothing")
    func writeSkipsUnchanged() {
        let settle = PositionWritePolicy.Settle(itemID: "item-20", sortKey: key(20), at: .now)
        let mine = EffectivePosition(scope: .all, markSortKey: key(20), updatedAt: .distantPast, deviceID: me)
        #expect(!PositionWritePolicy.shouldWrite(.init(
            settle: settle, stored: mine, arePositionsMerged: true, deviceID: me
        )))
    }

    @Test("Settling on another device's position claims it for this one")
    func writeClaimsForeign() {
        let settle = PositionWritePolicy.Settle(itemID: "item-20", sortKey: key(20), at: .now)
        let theirs = EffectivePosition(scope: .all, markSortKey: key(20), updatedAt: .distantPast, deviceID: other)
        #expect(PositionWritePolicy.shouldWrite(.init(
            settle: settle, stored: theirs, arePositionsMerged: true, deviceID: me
        )))
    }

    // MARK: - Adoption

    private func adoption(
        stored: EffectivePosition,
        targetRow: Int? = 3,
        foldRow: Int? = 7,
        lastLocalSettle: Date? = nil,
        lastAdopted: EffectivePosition? = nil,
        trigger: PositionWritePolicy.AdoptionTrigger = .activation,
        isQuiet: Bool = true,
        timeLeftAlone: Duration? = .seconds(1)
    ) -> PositionWritePolicy.AdoptionDecision {
        PositionWritePolicy.adoption(.init(
            stored: stored,
            deviceID: me,
            targetRow: targetRow,
            foldRow: foldRow,
            lastLocalSettle: lastLocalSettle,
            lastAdopted: lastAdopted,
            trigger: trigger,
            isQuiet: isQuiet,
            timeLeftAlone: timeLeftAlone
        ))
    }

    private var theirs: EffectivePosition {
        EffectivePosition(scope: .all, markSortKey: key(40), updatedAt: Date(timeIntervalSince1970: 1_000), deviceID: other)
    }

    @Test("Coming back to the device moves it to where the other one left off")
    func adoptOnActivation() {
        #expect(adoption(stored: theirs) == .scroll(row: 3))
    }

    @Test("This device's own position is never adopted")
    func adoptIgnoresOwn() {
        var mine = theirs
        mine.deviceID = me
        #expect(adoption(stored: mine) == .settled)
    }

    @Test("A report is applied once")
    func adoptOnce() {
        #expect(adoption(stored: theirs, lastAdopted: theirs) == .settled)
    }

    @Test("A report older than what the reader just did here is ignored")
    func adoptIgnoresStale() {
        #expect(adoption(stored: theirs, lastLocalSettle: Date(timeIntervalSince1970: 2_000)) == .settled)
        #expect(adoption(stored: theirs, lastLocalSettle: Date(timeIntervalSince1970: 500)) == .scroll(row: 3))
    }

    @Test("A report whose article has not arrived waits, unremembered")
    func adoptWaitsForArticle() {
        #expect(adoption(stored: theirs, targetRow: nil) == .notNow)
    }

    @Test("Never while the reader has hold of the list")
    func adoptWaitsForQuiet() {
        #expect(adoption(stored: theirs, isQuiet: false) == .notNow)
    }

    @Test("Without the reader coming back, only after the list has been left alone a while")
    func adoptWhenIdle() {
        #expect(adoption(stored: theirs, trigger: .idle, timeLeftAlone: .seconds(4)) == .notNow)
        #expect(adoption(stored: theirs, trigger: .idle, timeLeftAlone: .seconds(10)) == .scroll(row: 3))
    }

    @Test("Already there is handled without moving")
    func adoptAlreadyThere() {
        #expect(adoption(stored: theirs, targetRow: 7, foldRow: 7) == .settled)
    }
}
