import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// When a settled fold may be written down as this device's reading position.
///
/// The rule this pins is the one that made opening a device destructive. Positions are stored per
/// device and reduced by *most recently written*, so a write is a claim to be the authority — and
/// the timeline was making that claim on every launch, for a position it had merely restored. A
/// phone left alone for a week would open, republish its week-old place with today's timestamp,
/// and every other device would dutifully scroll back to it.
@Suite("Position publication")
struct PositionPublicationTests {

    private func key(_ millis: Int64) -> SortKey {
        SortKey(millis: millis, id: "i\(millis)")
    }

    /// Every case below but the last one is about a fold read from the list it is being written to,
    /// so that is the default and the scopes are named only where they are the point.
    private func shouldPublish(
        fold: SortKey,
        stored: SortKey?,
        isRestoredFold: Bool,
        foldScope: ScopeID? = .all,
        writingScope: ScopeID = .all
    ) -> Bool {
        PositionPublication.shouldPublish(
            fold: fold,
            stored: stored,
            isRestoredFold: isRestoredFold,
            foldScope: foldScope,
            writingScope: writingScope
        )
    }

    /// The regression. A restore reproduces what is already on record, so it has nothing to say —
    /// and saying it anyway re-dates a stale position into the freshest one in the system.
    @Test("A restored fold is never published")
    func restoredFoldIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(1_000),
                stored: key(1_000),
                isRestoredFold: true
            )
        )
    }

    /// Including when it lands slightly off. A restore that misses by a row is still only claiming
    /// "this is where I was", which is the thing already stored — and the miss is the *reason* not
    /// to publish it, since a republished miss is how the position used to creep.
    @Test("A restored fold is not published even when it differs from the stored key")
    func restoredFoldIsNotPublishedWhenItDrifts() {
        #expect(
            !shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: true
            )
        )
    }

    /// The reader moved, and where they moved to is new information.
    @Test("A fold the reader moved is published")
    func movedFoldIsPublished() {
        #expect(
            shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: false
            )
        )
    }

    /// Scrolling away and back again says nothing the store does not already hold, and a write is
    /// not free: it restamps every scope the cascade reaches and queues a sync record for each.
    @Test("A fold equal to the stored position is not published")
    func unchangedFoldIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(1_000),
                stored: key(1_000),
                isRestoredFold: false
            )
        )
    }

    /// Seeding a scope's first position belongs to ingest, which waits for the first sync pull
    /// before doing it so that a device cannot declare itself caught up before hearing from the
    /// others. A list that has not been told yet must not declare it either — that is the "opened
    /// the app and it says nothing is new" case.
    @Test("Nothing is published into a scope with no stored position")
    func unseededScopeIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(1_000),
                stored: .distantPast,
                isRestoredFold: false
            )
        )
    }

    /// Unreadable is not the same as absent, and the safe reading of "I could not find out what I
    /// am about to overwrite" is to overwrite nothing.
    @Test("Nothing is published when the stored position cannot be read")
    func unreadableStoredPositionIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(1_000),
                stored: nil,
                isRestoredFold: false
            )
        )
    }

    // MARK: - The fold belongs to the list it was read in

    /// The reported bug, in the rule's own terms. Older Items and All Items were the same view, so
    /// they were the same fold — and scrolling the one wrote the other's position. Every other rule
    /// here would have waved this through: the reader really did move, to a row that really does
    /// differ from what is stored. It is simply a row in a different list.
    @Test("A fold read in one list is not written as another list's position")
    func foldFromAnotherScopeIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: false,
                foldScope: .lateArrivals,
                writingScope: .all
            )
        )
    }

    /// Not a blanket refusal to write: the identical move, read in the list it is written to, is
    /// exactly what a reading position is for.
    @Test("The same move is published when it was read in the list being written")
    func foldFromTheSameScopeIsPublished() {
        #expect(
            shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: false,
                foldScope: .lateArrivals,
                writingScope: .lateArrivals
            )
        )
    }

    /// Two scopes of the same kind are still two scopes. A feed's fold is not its folder's, and the
    /// cascade — not a stray write — is what carries a position between them.
    @Test("A fold from a sibling scope is not published either")
    func foldFromASiblingScopeIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: false,
                foldScope: .source("feed/1"),
                writingScope: .source("feed/2")
            )
        )
    }

    /// A list that has never reported a fold has nothing to say about where the reader is, and
    /// "nowhere" must not read as "here".
    @Test("A fold that was never read is not published")
    func unreadFoldIsNotPublished() {
        #expect(
            !shouldPublish(
                fold: key(900),
                stored: key(1_000),
                isRestoredFold: false,
                foldScope: nil,
                writingScope: .all
            )
        )
    }
}

/// The reduction the rule above protects.
///
/// These are not tests of `PositionPublication`; they are what makes its job legible. Reduction
/// takes the most recently *written* row, which is correct only while writes mean "the reader went
/// here". The scenario below is the one that was reported, expressed in the reduction's own terms.
@Suite("Position reduction across devices")
struct PositionReductionScenarioTests {

    private func key(_ millis: Int64) -> SortKey {
        SortKey(millis: millis, id: "i\(millis)")
    }

    /// A phone that is a hundred items behind, opened after a Mac has caught up.
    ///
    /// With the restore republishing, the phone's launch wrote its old place at `now` and won.
    /// Without it, the phone writes nothing and the Mac's position stands — which is what the
    /// second Mac then adopts.
    @Test("A device opening while behind does not outrank one that is further ahead")
    func openingWhileBehindDoesNotWin() {
        let macCaughtUp = Date(timeIntervalSince1970: 2_000)
        let phoneLastRead = Date(timeIntervalSince1970: 1_000)

        let position = EffectivePosition.reduce(
            [
                (deviceID: "phone", markSortKey: key(100), updatedAt: phoneLastRead),
                (deviceID: "mac-a", markSortKey: key(999), updatedAt: macCaughtUp),
            ],
            scope: .all
        )

        #expect(position.deviceID == "mac-a")
        #expect(position.markSortKey == key(999))
    }

    /// And the converse, so this is not simply asserting that the Mac always wins: a reader who
    /// genuinely scrolls on the phone afterwards *is* the most recent reader, and must win.
    @Test("A device the reader actually moves does outrank the others")
    func genuineMovementWins() {
        let position = EffectivePosition.reduce(
            [
                (deviceID: "phone", markSortKey: key(100), updatedAt: Date(timeIntervalSince1970: 3_000)),
                (deviceID: "mac-a", markSortKey: key(999), updatedAt: Date(timeIntervalSince1970: 2_000)),
            ],
            scope: .all
        )

        #expect(position.deviceID == "phone")
        #expect(position.markSortKey == key(100))
    }
}
