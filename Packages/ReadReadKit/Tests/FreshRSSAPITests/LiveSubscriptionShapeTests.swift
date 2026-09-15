import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import FreshRSSAPI

/// The exact bytes `greader.php` emits from `subscriptionList()`, including the `frss:priority`
/// extension and an absolute `iconUrl` — copied from the source rather than paraphrased.
@Suite("Live subscription shape")
struct LiveSubscriptionShapeTests {

    private let loginBody = "SID=matze/tok\nAuth=matze/tok"
    private let accountID = UUID()

    private let payload = """
    {"subscriptions":[\
    {"id":"feed/2","title":"Daring Fireball","categories":[{"id":"user/-/label/Apple","label":"Apple"}],\
    "url":"https://daringfireball.net/feeds/main","htmlUrl":"https://daringfireball.net/",\
    "iconUrl":"https://rss.example.com/f.php?54","frss:priority":10},\
    {"id":"feed/7","title":"Uncategorised Feed","categories":[{"id":"user/-/label/","label":""}],\
    "url":"https://example.com/feed","htmlUrl":"","iconUrl":"","frss:priority":10}\
    ]}
    """

    @Test("A real subscription list lands in the store as sources")
    func decodesAndStores() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)
        await sink.configure(deviceID: "device-a")

        let transport = StubTransport([.text(loginBody), .json(payload)])
        let client = GReaderClient(
            baseURL: URL(string: "https://rss.example.com")!,
            credentials: .init(username: "matze", apiPassword: "p"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        let planner = FreshRSSIngestPlanner(client: client, sink: sink, accountID: accountID)

        _ = try await planner.refreshSubscriptions()

        let sources = try ModelContext(container).fetch(FetchDescriptor<CachedSource>())
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.isSubscribed })
        #expect(sources.contains { $0.title == "Daring Fireball" && $0.folderName == "Apple" })
        // An empty category label must read as "no folder", not as a folder named "".
        #expect(sources.contains { $0.title == "Uncategorised Feed" && $0.folderName == nil })
    }

    @Test("An empty list does not unsubscribe everything")
    func emptyListDoesNotWipe() async throws {
        let container = try ReadReadStore.inMemoryContainer()
        let sink = SwiftDataIngestSink(modelContainer: container)
        await sink.configure(deviceID: "device-a")

        let first = StubTransport([.text(loginBody), .json(payload)])
        _ = try await FreshRSSIngestPlanner(
            client: GReaderClient(
                baseURL: URL(string: "https://rss.example.com")!,
                credentials: .init(username: "matze", apiPassword: "p"),
                http: HTTPClient(transport: first, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            sink: sink,
            accountID: accountID
        ).refreshSubscriptions()

        let second = StubTransport([.text(loginBody), .json(#"{"subscriptions":[]}"#)])
        _ = try await FreshRSSIngestPlanner(
            client: GReaderClient(
                baseURL: URL(string: "https://rss.example.com")!,
                credentials: .init(username: "matze", apiPassword: "p"),
                http: HTTPClient(transport: second, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            ),
            sink: sink,
            accountID: accountID
        ).refreshSubscriptions()

        let sources = try ModelContext(container).fetch(FetchDescriptor<CachedSource>())
        // A 200 with an empty body is what a half-authenticated server returns, and taking it at
        // face value hides every feed the user has.
        #expect(sources.allSatisfy { $0.isSubscribed })
    }
}
