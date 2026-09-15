import Foundation
import SwiftData
import Testing

@testable import ReadReadModel

/// The reduction has to say *whose* position won, not just what it is.
///
/// Everything downstream of sync depended on that and could not ask: the open timeline had no way
/// to tell a position it had just written from one the other device had sent, so it left the list
/// where it was and then overwrote the incoming position with its own. Both devices pushed and
/// pulled faithfully — a server log showed dozens of exchanges — and neither ever moved.
@Suite("Remote positions")
struct RemotePositionTests {

    private func marks(
        _ entries: [(String, Int64, TimeInterval)]
    ) -> [(deviceID: String, markSortKey: SortKey, updatedAt: Date)] {
        entries.map { (deviceID: $0.0, markSortKey: SortKey(millis: $0.1, id: $0.0), updatedAt: Date(timeIntervalSince1970: $0.2)) }
    }

    @Test("The winning row names its device")
    func reportsTheWinningDevice() {
        let effective = EffectivePosition.reduce(
            marks([("mac", 1_000, 100), ("iphone", 2_000, 200)]),
            scope: .all
        )

        #expect(effective.deviceID == "iphone")
        #expect(effective.markSortKey == SortKey(millis: 2_000, id: "iphone"))
    }

    @Test("A device recognises its own position coming back")
    func recognisesItsOwnPosition() {
        // The case that matters while reading: this device's own row is the newest, so nothing
        // should be adopted and the list must not be scrolled out from under the reader.
        let effective = EffectivePosition.reduce(
            marks([("iphone", 2_000, 100), ("mac", 1_000, 200)]),
            scope: .all
        )

        #expect(effective.deviceID == "mac")
    }

    @Test("A scope no device has a position in names no device")
    func unreadNamesNoDevice() {
        #expect(EffectivePosition.reduce([], scope: .all).deviceID == nil)
        #expect(EffectivePosition.unread(.all).deviceID == nil)
    }

    @Test("The device survives a round trip through the store")
    func deviceSurvivesThePositionRoundTrip() throws {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let key = SortKey(millis: 5_000, id: "x")
        try ThresholdService.setPosition(.all, to: key, deviceID: "mac", in: context)
        try context.save()

        let effective = try ThresholdService.effectivePosition(for: .all, in: context)
        #expect(effective.deviceID == "mac")
        #expect(effective.markSortKey == key)
    }
}
