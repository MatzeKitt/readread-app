import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import ReadReadSync

@Suite("SyncClient")
struct SyncClientTests {

    private func makeClient(_ transport: StubTransport, base: String = "https://sync.example.net") -> SyncClient {
        SyncClient(
            configuration: SyncConfiguration(baseURL: URL(string: base)!, token: "tok-123"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    // MARK: - URLs

    /// The README shows the base URL both bare and with the API prefix, and people paste either.
    @Test("Base URL variants resolve to the same endpoint", arguments: [
        "https://sync.example.net",
        "https://sync.example.net/",
        "https://sync.example.net/api",
        "https://sync.example.net/api/v1",
        "https://sync.example.net/api/v1/",
    ])
    func baseURLVariantsNormalise(base: String) throws {
        let url = try SyncClient.endpoint(baseURL: URL(string: base)!, path: "changes", query: [])

        #expect(url.absoluteString == "https://sync.example.net/api/v1/changes")
    }

    @Test("A service in a subdirectory keeps its path")
    func subdirectoryKeepsPath() throws {
        let url = try SyncClient.endpoint(
            baseURL: URL(string: "https://example.net/readread-sync")!,
            path: "health",
            query: []
        )

        #expect(url.absoluteString == "https://example.net/readread-sync/api/v1/health")
    }

    // MARK: - Requests

    @Test("Pull sends the cursor and carries the bearer token")
    func pullSendsCursor() async throws {
        let transport = StubTransport([.json(#"{"records":[],"maxRevision":7,"hasMore":false}"#)])
        let client = makeClient(transport)

        let page = try await client.pull(since: 4, limit: 100)

        #expect(page.maxRevision == 7)
        let query = await transport.queryItems(at: 0)
        #expect(query["since"] == "4")
        #expect(query["limit"] == "100")
        #expect(await transport.header("Authorization", at: 0) == "Bearer tok-123")
    }

    @Test("A negative cursor is clamped rather than sent")
    func negativeCursorIsClamped() async throws {
        let transport = StubTransport([.json(#"{"records":[],"maxRevision":0,"hasMore":false}"#)])
        let client = makeClient(transport)

        _ = try await client.pull(since: -5)

        #expect(await transport.queryItems(at: 0)["since"] == "0")
    }

    /// Health is unauthenticated so account setup can tell "wrong URL" from "wrong token" — two
    /// distinct problems that a single 401 would conflate.
    @Test("Health is sent without a token")
    func healthIsUnauthenticated() async throws {
        let transport = StubTransport([.json(#"{"ok":true,"service":"readread-sync","version":"1.0.0"}"#)])
        let client = makeClient(transport)

        let health = try await client.health()

        #expect(health.ok)
        #expect(health.service == "readread-sync")
        #expect(await transport.header("Authorization", at: 0) == nil)
    }

    @Test("Push posts the records array")
    func pushPostsRecords() async throws {
        let transport = StubTransport([.json(#"{"applied":[{"collection":"position","id":"all|mac","revision":9}],"maxRevision":9}"#)])
        let client = makeClient(transport)

        let result = try await client.push([
            SyncPushRecord(collection: .position, id: "all|mac", payload: #"{"gen":0}"#),
        ])

        #expect(result.applied.first?.revision == 9)
        #expect(await transport.requests[0].httpMethod == "POST")

        let body = await transport.body(at: 0)
        #expect(body.contains(#""collection":"position""#))
        #expect(body.contains(#""id":"all|mac""#))
    }

    @Test("An empty push makes no request at all")
    func emptyPushSkipsRequest() async throws {
        let transport = StubTransport([])
        let client = makeClient(transport)

        let result = try await client.push([])

        #expect(result.applied.isEmpty)
        #expect(await transport.requestCount == 0)
    }

    @Test("An unconfigured client refuses rather than guessing a URL")
    func unconfiguredClientThrows() async throws {
        let client = SyncClient(configuration: nil, http: HTTPClient(transport: StubTransport([])))

        await #expect(throws: SyncError.notConfigured) {
            _ = try await client.pull(since: 0)
        }
    }

    // MARK: - Error translation

    /// A 400 and a 500 need opposite handling: a rejected record will fail identically forever and
    /// must leave the outbox, while a 500 is worth retrying.
    @Test("A rejection is distinguished from a server error")
    func rejectionIsDistinguished() {
        let rejected = SyncClient.translate(
            .status(code: 400, body: #"{"error":"bad_request","message":"Unknown collection"}"#)
        )
        #expect(rejected as? SyncError == .rejected("Unknown collection"))

        let unauthorized = SyncClient.translate(.status(code: 401, body: ""))
        #expect(unauthorized as? SyncError == .unauthorized)

        // A 500 stays an HTTPError so the retry machinery still treats it as transient.
        let serverError = SyncClient.translate(.status(code: 500, body: "boom"))
        #expect(serverError is HTTPError)
    }

    @Test("A rejection without a JSON body still reports something useful")
    func rejectionWithoutJSONBody() {
        let error = SyncClient.translate(.status(code: 413, body: "Request Entity Too Large"))

        #expect(error as? SyncError == .rejected("Request Entity Too Large"))
    }

    @Test("An unknown collection from a newer server is reported, not silently dropped")
    func unknownCollectionIsReported() async throws {
        let transport = StubTransport([
            .json(#"{"records":[{"collection":"futureThing","id":"x","revision":1,"deleted":false,"updatedAt":0,"payload":"{}"}],"maxRevision":1,"hasMore":false}"#),
        ])
        let client = makeClient(transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.pull(since: 0)
        }
    }

    @Test("HTML instead of JSON is reported as unexpected")
    func htmlIsReportedClearly() async throws {
        let transport = StubTransport([.text("<html>404 Not Found</html>")])
        let client = makeClient(transport)

        do {
            _ = try await client.pull(since: 0)
            Issue.record("expected a failure")
        } catch let error as SyncError {
            guard case .unexpectedResponse = error else {
                Issue.record("expected .unexpectedResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - Decoding

    @Test("A record decodes with defaults for optional fields")
    func recordDecodesWithDefaults() throws {
        let json = #"{"collection":"filter","id":"f1","revision":3}"#
        let record = try JSONDecoder().decode(SyncRecord.self, from: Data(json.utf8))

        #expect(record.collection == .filter)
        #expect(record.deleted == false)
        #expect(record.payload.isEmpty)
    }

    @Test("A tombstone decodes")
    func tombstoneDecodes() throws {
        let json = #"{"collection":"filter","id":"f1","revision":5,"deleted":true,"updatedAt":123,"payload":""}"#
        let record = try JSONDecoder().decode(SyncRecord.self, from: Data(json.utf8))

        #expect(record.deleted)
        #expect(record.payload.isEmpty)
    }
}
