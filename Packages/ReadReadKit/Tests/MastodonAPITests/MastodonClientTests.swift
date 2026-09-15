import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

@Suite("MastodonClient")
struct MastodonClientTests {

    private func makeClient(_ transport: StubTransport, token: String? = "tok") -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: token,
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    // MARK: - Instance URL normalisation

    /// People type an instance in every one of these forms, and the account setup screen should not
    /// have to know the difference.
    @Test("Instance input normalises to a base URL", arguments: [
        ("mastodon.social", "https://mastodon.social"),
        ("https://mastodon.social", "https://mastodon.social"),
        ("https://mastodon.social/", "https://mastodon.social"),
        ("HTTPS://mastodon.social", "https://mastodon.social"),
        ("@matze@mastodon.social", "https://mastodon.social"),
        ("matze@mastodon.social", "https://mastodon.social"),
        ("  mastodon.social  ", "https://mastodon.social"),
        ("https://mastodon.social/@matze", "https://mastodon.social"),
        ("https://mastodon.social/api/v1/timelines/home", "https://mastodon.social"),
    ])
    func normalisesInstanceInput(input: String, expected: String) {
        #expect(MastodonClient.normalisedInstanceURL(from: input)?.absoluteString == expected)
    }

    @Test("Input that is not a host is rejected", arguments: ["", "   ", "notahost", "@", "http://"])
    func rejectsNonHosts(input: String) {
        #expect(MastodonClient.normalisedInstanceURL(from: input) == nil)
    }

    // MARK: - Link header parsing

    /// The guidelines prefer following `Link` over building `max_id` by hand, since the server
    /// knows its own id scheme.
    @Test("Extracts max_id from the rel=next link")
    func extractsNextMaxID() {
        let header = """
        <https://mastodon.social/api/v1/timelines/home?max_id=110451234567890001>; rel="next", \
        <https://mastodon.social/api/v1/timelines/home?min_id=110451234567890003>; rel="prev"
        """

        #expect(MastodonClient.maxID(fromLinkHeader: header) == "110451234567890001")
    }

    @Test("Ignores the prev link even when it comes first")
    func ignoresPrevLink() {
        let header = """
        <https://mastodon.social/api/v1/timelines/home?min_id=999>; rel="prev", \
        <https://mastodon.social/api/v1/timelines/home?max_id=111>; rel="next"
        """

        #expect(MastodonClient.maxID(fromLinkHeader: header) == "111")
    }

    /// A URL's query string can legitimately contain a comma, so splitting the header on every
    /// comma would corrupt the link and lose the cursor.
    @Test("A comma inside the URL does not break parsing")
    func commaInsideURLIsSafe() {
        let header = #"<https://host/api/v1/timelines/home?types[]=a,b&max_id=222>; rel="next""#

        #expect(MastodonClient.maxID(fromLinkHeader: header) == "222")
    }

    @Test("Unquoted rel is accepted, as some proxies rewrite it")
    func unquotedRelAccepted() {
        #expect(MastodonClient.maxID(fromLinkHeader: "<https://host/x?max_id=333>; rel=next") == "333")
    }

    /// No `next` link is how the server says there is nothing older — the signal that ends a walk.
    @Test("Absent, empty or next-less headers yield nil", arguments: [
        String?.none,
        "",
        #"<https://host/x?min_id=1>; rel="prev""#,
        #"<https://host/x>; rel="next""#,
        "garbage",
    ])
    func missingNextYieldsNil(header: String?) {
        #expect(MastodonClient.maxID(fromLinkHeader: header) == nil)
    }

    // MARK: - Timeline requests

    @Test("Home timeline requests the documented maximum page size")
    func requestsMaximumPageSize() async throws {
        let transport = StubTransport([.json("[]")])
        let client = makeClient(transport)

        _ = try await client.homeTimeline()

        let query = await transport.queryItems(at: 0)
        // 40 is the documented cap; asking for more is silently clamped, so 40 minimises round trips.
        #expect(query["limit"] == "40")
        #expect(query["max_id"] == nil)
    }

    @Test("A limit above the cap is clamped rather than sent through")
    func limitIsClamped() async throws {
        let transport = StubTransport([.json("[]")])
        let client = makeClient(transport)

        _ = try await client.homeTimeline(limit: 200)

        #expect(await transport.queryItems(at: 0)["limit"] == "40")
    }

    @Test("max_id is sent when paginating, and omitted when empty", arguments: [
        (String?.some("110451234567890001"), String?.some("110451234567890001")),
        (String?.some(""), String?.none),
        (String?.none, String?.none),
    ])
    func sendsMaxIDWhenMeaningful(maxID: String?, expected: String?) async throws {
        let transport = StubTransport([.json("[]")])
        let client = makeClient(transport)

        _ = try await client.homeTimeline(maxID: maxID)

        #expect(await transport.queryItems(at: 0)["max_id"] == expected)
    }

    @Test("Requests carry the bearer token")
    func requestsCarryBearerToken() async throws {
        let transport = StubTransport([.json("[]")])
        let client = makeClient(transport)

        _ = try await client.homeTimeline()

        #expect(await transport.header("Authorization", at: 0) == "Bearer tok")
    }

    @Test("The page's next cursor comes from the Link header")
    func pageCarriesNextCursor() async throws {
        let transport = StubTransport([
            .statusWithHeaders(
                200,
                headers: ["Link": #"<https://mastodon.social/api/v1/timelines/home?max_id=555>; rel="next""#],
                body: "[]"
            ),
        ])
        let client = makeClient(transport)

        let page = try await client.homeTimeline()

        #expect(page.nextMaxID == "555")
    }

    /// Unlike FreshRSS there is nothing to re-derive: a Mastodon token is valid until revoked, so a
    /// 401 means the user signed the app out from the instance and must authorise again. Retrying
    /// would fail identically.
    @Test("A 401 surfaces as a revoked token with no retry")
    func unauthorizedMeansRevoked() async throws {
        let transport = StubTransport([.status(401, body: "The access token was revoked")])
        let client = makeClient(transport)

        do {
            _ = try await client.homeTimeline()
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .tokenRevoked = error else {
                Issue.record("expected .tokenRevoked, got \(error)")
                return
            }
        }
        #expect(await transport.requestCount == 1)
    }

    /// Pointing at a host that is not a Mastodon instance returns HTML with a 200. Naming that is
    /// far more useful than a key-not-found error about JSON the user never saw.
    @Test("A non-Mastodon host is reported as an unexpected response")
    func nonMastodonHostIsReported() async throws {
        let transport = StubTransport([.text("<html><title>Some blog</title></html>")])
        let client = makeClient(transport)

        do {
            _ = try await client.homeTimeline()
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .unexpectedResponse = error else {
                Issue.record("expected .unexpectedResponse, got \(error)")
                return
            }
        }
    }

    @Test("verify_credentials decodes")
    func verifyCredentialsDecodes() async throws {
        let transport = StubTransport([.json("""
        {"id":"1","username":"matze","acct":"matze","display_name":"Matze",
         "avatar":"https://x/a.png","url":"https://mastodon.social/@matze"}
        """)])
        let client = makeClient(transport)

        let account = try await client.verifyCredentials()

        #expect(account.acct == "matze")
        #expect(account.displayName == "Matze")
    }

    @Test("Endpoint URLs are built from the instance base")
    func buildsEndpointURLs() throws {
        let url = try MastodonClient.endpoint(
            instanceURL: URL(string: "https://mastodon.social/")!,
            path: "api/v1/timelines/home",
            query: [URLQueryItem(name: "limit", value: "40")]
        )

        #expect(url.absoluteString == "https://mastodon.social/api/v1/timelines/home?limit=40")
    }
}
