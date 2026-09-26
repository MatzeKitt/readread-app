import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadSync

/// Positions are ordered by wall clock, and the clocks belong to different machines. A device whose
/// clock has slipped loses with a genuinely newer position and there is nothing on screen to say
/// why — so the measurement is the whole feature, and these pin down what it says.
@Suite("Clock skew")
struct ClockSkewTests {

    // MARK: - The rule

    @Test("Ahead is positive, behind is negative")
    func sign() {
        let server = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ClockSkew.seconds(localNow: server.addingTimeInterval(300), serverNow: server) == 300)
        #expect(ClockSkew.seconds(localNow: server.addingTimeInterval(-300), serverNow: server) == -300)
    }

    /// Ordinary drift between two of someone's own devices is seconds, and saying so would be
    /// noise in a screen the reader opened to find a real fault.
    @Test("Drift is not worth reporting")
    func driftIsQuiet() {
        #expect(!ClockSkew.isWorthReporting(0))
        #expect(!ClockSkew.isWorthReporting(45))
        #expect(!ClockSkew.isWorthReporting(-45))
        #expect(ClockSkew.warning(for: 45) == nil)
    }

    @Test("A skew past the threshold is reported in both directions")
    func faultIsReported() {
        #expect(ClockSkew.isWorthReporting(ClockSkew.threshold))
        #expect(ClockSkew.isWorthReporting(-ClockSkew.threshold))
        #expect(ClockSkew.warning(for: 600) != nil)
        #expect(ClockSkew.warning(for: -600) != nil)
    }

    /// The two directions are different faults and have to read differently: behind loses a place,
    /// ahead holds one the reader has left.
    @Test("The two directions say different things")
    func directionsDiffer() {
        #expect(ClockSkew.warning(for: 600) != ClockSkew.warning(for: -600))
    }

    // MARK: - The measurement

    @Test("A run records the clock it saw")
    func runRecordsTheSkew() async throws {
        // Far enough in the past that no plausible test-machine clock makes this ambiguous.
        let serverNow = Date(timeIntervalSince1970: 784_111_777)
        let transport = StubTransport([
            .statusWithHeaders(
                200,
                headers: ["Date": "Sun, 06 Nov 1994 08:49:37 GMT"],
                body: #"{"records":[],"maxRevision":0,"hasMore":false}"#
            ),
        ])
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: "https://sync.example.net")!, token: "t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )

        _ = try await SyncCoordinator(client: client, store: store).sync()

        let state = try #require(
            try ModelContext(container).fetch(FetchDescriptor<SyncState>()).first
        )
        let skew = try #require(state.clockSkewSeconds)
        // This machine's clock against 1994: hugely ahead, and unmistakably a fault.
        #expect(skew > 0)
        #expect(ClockSkew.isWorthReporting(skew))
        #expect(abs(skew - Date.now.timeIntervalSince(serverNow)) < 60)
        #expect(state.clockSkewCheckedAt != nil)
    }

    /// A response with no `Date` leaves the figure alone rather than recording agreement. The
    /// endpoint is self-hosted and whatever sits in front of it may strip headers; "not known" and
    /// "in agreement" are different answers and only one of them is honest.
    @Test("A reply without a Date header records nothing")
    func noHeaderRecordsNothing() async throws {
        let transport = StubTransport([.json(#"{"records":[],"maxRevision":0,"hasMore":false}"#)])
        let container = try ReadReadStore.inMemoryContainer()
        let store = SyncStore(modelContainer: container)
        let client = SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: "https://sync.example.net")!, token: "t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )

        _ = try await SyncCoordinator(client: client, store: store).sync()

        let state = try ModelContext(container).fetch(FetchDescriptor<SyncState>()).first
        #expect(state?.clockSkewSeconds == nil)
    }
}
