import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// The badge after a pull, rather than after a feed refresh.
///
/// The count on the icon is a function of the item set **and** the reading position, and until
/// this it only ever followed the first. A completed feed refresh published it, and so did the
/// reader's own settled scroll — but a position pulled from the *other* device published nothing.
/// So reading on the Mac and then glancing at the phone showed the sidebar counts already
/// corrected and the icon still carrying a number from up to fifteen minutes earlier.
@Suite("Badge after a pull")
struct BadgeAfterPullTests {

    private actor Recorder {
        private(set) var writes: [Int] = []
        nonisolated func setter() -> BadgePublisher.Setter {
            { [weak self] count in await self?.record(count) }
        }
        private func record(_ count: Int) { writes.append(count) }
    }

    private static let deviceID = "device-A"
    private static let foreignDevice = "device-B"

    private func makeEndpoint() throws -> SyncEndpoint {
        let defaults = UserDefaults(suiteName: "readread.tests.\(UUID().uuidString)")!
        let keychain = KeychainStore(
            service: "com.kittmedia.ReadRead.tests.\(UUID().uuidString)",
            prefersDataProtectionKeychain: false
        )
        let endpoint = SyncEndpoint(defaults: defaults, keychain: keychain)
        endpoint.saveSettings(SyncEndpointSettings(urlString: "https://sync.example.net", isEnabled: true))
        try endpoint.setToken("t")
        return endpoint
    }

    /// Three items and no position at all, so everything counts.
    private func populate(_ context: ModelContext) throws -> [CachedItem] {
        let accountID = UUID()
        var items: [CachedItem] = []
        for offset in 0..<3 {
            let id = "freshrss:\(accountID.uuidString):item\(offset)"
            let key = SortKey(millis: 1_700_000_000_000 + Int64(offset), id: id)
            let item = CachedItem(
                id: id,
                sourceID: "freshrss:\(accountID.uuidString):feed/1",
                accountID: accountID,
                kind: .article,
                title: "Item \(offset)",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sortKey: key,
                ingestKey: key
            )
            context.insert(item)
            items.append(item)
        }
        try context.save()
        return items
    }

    /// One `all` position written by the other device.
    ///
    /// - Parameter writtenAt: Deliberately a fixed date in the past rather than `.now`. Reduction
    ///   orders on wall clock and `SyncStore` clamps anything far in the future, so a fixture
    ///   dated ahead of the test run would win every comparison it was written to lose.
    private func pullPage(
        marking item: CachedItem,
        writtenAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> StubTransport.Response {
        let payload = try SyncPayloadCoding.encodeToString(PositionPayload(
            scope: ScopeID.all.rawValue,
            deviceID: Self.foreignDevice,
            markSortKey: item.sortKeyRaw,
            updatedAt: writtenAt
        )).replacingOccurrences(of: "\"", with: "\\\"")

        let record = #"{"collection":"position","id":"all|\#(Self.foreignDevice)","revision":1,"deleted":false,"updatedAt":1,"payload":"\#(payload)"}"#
        return .json(#"{"records":[\#(record)],"maxRevision":1,"hasMore":false}"#)
    }

    private func makeEngine(
        container: ModelContainer,
        badge: BadgePublisher,
        transport: StubTransport
    ) throws -> RefreshEngine {
        RefreshEngine(
            container: container,
            endpoint: try makeEndpoint(),
            syncClient: SyncClient(
                http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            badge: badge
        )
    }

    /// The regression, end to end: a sync run that pulls a position moves the icon.
    @Test("A pulled position republishes the badge")
    func pulledPositionRepublishesTheBadge() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let items = try populate(context)

        let recorder = Recorder()
        let badge = BadgePublisher(setBadge: recorder.setter())
        // The baseline a completed feed refresh would have established. Without one the publisher
        // refuses — there is no trustworthy item set to combine a position with yet.
        await badge.publish(count: 3, report: RefreshRunReport(ingestComplete: true, syncSucceeded: true))

        let engine = try makeEngine(
            container: container,
            badge: badge,
            transport: StubTransport([try pullPage(marking: items[2])])
        )

        try await engine.perform(.syncState, trigger: .manual)

        // The other device read to the end, so nothing is newer any more — and the icon says so
        // rather than waiting for a feed refresh to notice.
        #expect(await recorder.writes == [3, 0])
    }

    /// The common case by far, and it must stay silent: a sync that applied nothing has nothing to
    /// say about the count, and writing the badge on every 30 s tick would be a cross-process call
    /// per tick for no effect.
    @Test("A pull that changed nothing does not touch the badge")
    func emptyPullDoesNotRepublish() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        _ = try populate(ModelContext(container))

        let recorder = Recorder()
        let badge = BadgePublisher(setBadge: recorder.setter())
        await badge.publish(count: 3, report: RefreshRunReport(ingestComplete: true, syncSucceeded: true))

        let engine = try makeEngine(
            container: container,
            badge: badge,
            transport: StubTransport([.json(#"{"records":[],"maxRevision":0,"hasMore":false}"#)])
        )

        try await engine.perform(.syncState, trigger: .manual)

        #expect(await recorder.writes == [3])
    }

    /// A position that loses the reduction is still an applied record, so the badge is recomputed
    /// — and recomputing it has to arrive at the number this device already had.
    @Test("A stale pulled position leaves the badge where it is")
    func stalePulledPositionDoesNotMoveTheBadge() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        let items = try populate(context)

        // This device is already at the end, and said so later than the record about to arrive.
        try ThresholdService.setPosition(.all, to: items[2].sortKey, deviceID: Self.deviceID, in: context)
        try context.save()

        let recorder = Recorder()
        let badge = BadgePublisher(setBadge: recorder.setter())
        await badge.publish(count: 0, report: RefreshRunReport(ingestComplete: true, syncSucceeded: true))

        let engine = try makeEngine(
            container: container,
            badge: badge,
            transport: StubTransport([try pullPage(marking: items[0])])
        )

        try await engine.perform(.syncState, trigger: .manual)

        // Recomputed, unchanged, and therefore not written: `publishPositionChange` skips a value
        // equal to the one already on the icon.
        #expect(await recorder.writes == [0])
    }
}
