import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import FreshRSSAPI

@Suite("GReaderClient")
struct GReaderClientTests {

    private let credentials = GReaderClient.Credentials(username: "matze", apiPassword: "s3cret")

    private func makeClient(_ transport: StubTransport, base: String = "https://rss.example.net") -> GReaderClient {
        GReaderClient(
            baseURL: URL(string: base)!,
            credentials: credentials,
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    private let loginBody = """
    SID=matze/9f8e7d6c5b4a
    LSID=null
    Auth=matze/9f8e7d6c5b4a
    """

    // MARK: - URL construction

    /// The base URL is typed by hand or pasted from the FreshRSS profile page, which already shows
    /// it including `/api/`. All of these have to land on the same endpoint or the app appears
    /// broken for reasons the user cannot see.
    @Test("Base URL variants all resolve to the same API path", arguments: [
        "https://rss.example.net",
        "https://rss.example.net/",
        "https://rss.example.net/api",
        "https://rss.example.net/api/",
        "https://rss.example.net/api/greader.php",
        "https://rss.example.net/api/greader.php/",
    ])
    func baseURLVariantsNormalise(base: String) throws {
        let url = try GReaderClient.apiURL(
            baseURL: URL(string: base)!,
            path: "subscription/list",
            query: [URLQueryItem(name: "output", value: "json")]
        )

        #expect(url.absoluteString == "https://rss.example.net/api/greader.php/reader/api/0/subscription/list?output=json")
    }

    @Test("A FreshRSS install in a subdirectory keeps its path")
    func subdirectoryInstallKeepsPath() throws {
        let url = try GReaderClient.apiURL(
            baseURL: URL(string: "https://example.net/freshrss/api/greader.php")!,
            path: "tag/list",
            query: []
        )

        #expect(url.absoluteString == "https://example.net/freshrss/api/greader.php/reader/api/0/tag/list")
    }

    @Test("Login URL is built from the same base")
    func loginURLIsBuilt() throws {
        let url = try GReaderClient.loginURL(baseURL: URL(string: "https://rss.example.net/api/")!)

        #expect(url.absoluteString == "https://rss.example.net/api/greader.php/accounts/ClientLogin")
    }

    // MARK: - ClientLogin

    @Test("Extracts the Auth token, ignoring SID and LSID")
    func extractsAuthToken() {
        #expect(GReaderClient.authToken(inLoginResponse: loginBody) == "matze/9f8e7d6c5b4a")
    }

    @Test("Tolerates CRLF line endings and trailing whitespace")
    func toleratesLineEndingVariants() {
        let body = "SID=x\r\nLSID=null\r\nAuth=matze/abc  \r\n"

        #expect(GReaderClient.authToken(inLoginResponse: body) == "matze/abc")
    }

    /// A server that authenticates but hands back an empty token is malformed, not authorised —
    /// sending `GoogleLogin auth=` would fail every subsequent call with a confusing 401.
    @Test("An empty or missing Auth line yields no token", arguments: [
        "SID=x\nLSID=null\n",
        "SID=x\nAuth=\n",
        "Auth=   \n",
        "",
        "<html>Login page</html>",
    ])
    func rejectsMissingOrEmptyToken(body: String) {
        #expect(GReaderClient.authToken(inLoginResponse: body) == nil)
    }

    @Test("Login posts credentials in the body, never in the query")
    func loginPostsCredentials() async throws {
        let transport = StubTransport([.text(loginBody)])
        let client = makeClient(transport)

        _ = try await client.authenticate()

        #expect(await transport.requests[0].httpMethod == "POST")
        // FreshRSS logs a warning for the GET form precisely because the password lands in the
        // server's access log.
        #expect(await transport.urls[0].contains("Passwd") == false)
        let body = await transport.body(at: 0)
        #expect(body.contains("Email=matze"))
        #expect(body.contains("Passwd=s3cret"))
    }

    /// `.urlQueryAllowed` permits `+`, `&` and `=`, all of which change a form body's meaning. A
    /// password containing `+` would otherwise arrive as a space and the login would just fail.
    @Test("Passwords with form-significant characters are percent-encoded")
    func encodesAwkwardPasswords() async throws {
        let transport = StubTransport([.text(loginBody)])
        let client = GReaderClient(
            baseURL: URL(string: "https://rss.example.net")!,
            credentials: .init(username: "a b", apiPassword: "p+q&r=s/t"),
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )

        _ = try await client.authenticate()

        let body = await transport.body(at: 0)
        #expect(body.contains("Passwd=p%2Bq%26r%3Ds%2Ft"))
        #expect(body.contains("Email=a%20b"))
    }

    @Test("Rejected credentials surface as invalidCredentials")
    func rejectedCredentialsAreTyped() async throws {
        let transport = StubTransport([.status(401, body: "Unauthorized")])
        let client = makeClient(transport)

        await #expect(throws: GReaderError.self) {
            _ = try await client.authenticate()
        }
    }

    /// Pointing the app at the site root rather than the API returns the FreshRSS web page with a
    /// 200. Reporting that as a malformed login response is far more useful than a decode error.
    @Test("A non-API endpoint surfaces as a malformed login response")
    func nonAPIEndpointIsReported() async throws {
        let transport = StubTransport([.text("<!doctype html><title>FreshRSS</title>")])
        let client = makeClient(transport)

        do {
            _ = try await client.authenticate()
            Issue.record("expected a failure")
        } catch let error as GReaderError {
            guard case .malformedLoginResponse = error else {
                Issue.record("expected .malformedLoginResponse, got \(error)")
                return
            }
        }
    }

    @Test("The token is cached, so a second call does not log in again")
    func tokenIsCached() async throws {
        let transport = StubTransport([.text(loginBody)])
        let client = makeClient(transport)

        let first = try await client.authenticate()
        let second = try await client.authenticate()

        #expect(first == second)
        #expect(await transport.requestCount == 1)
    }

    /// Several ingest sections can hit a 401 at once. Without coalescing they would each start
    /// their own `ClientLogin` and stampede the server.
    @Test("Concurrent authentication coalesces into one login")
    func concurrentLoginsCoalesce() async throws {
        let transport = StubTransport([.text(loginBody)])
        let client = makeClient(transport)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.authenticate() }
            }
            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }

        #expect(tokens.count == 8)
        #expect(Set(tokens).count == 1)
        #expect(await transport.requestCount == 1)
    }

    // MARK: - Authorised requests

    @Test("Requests carry the GoogleLogin header")
    func requestsCarryAuthHeader() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"tags":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.tags()

        #expect(await transport.header("Authorization", at: 1) == "GoogleLogin auth=matze/9f8e7d6c5b4a")
    }

    /// FreshRSS tokens derive from the API password hash and change when the user rotates it.
    /// Without this single retry the app would keep failing until relaunch.
    @Test("A 401 mid-session re-authenticates once and retries")
    func staleTokenTriggersReauthentication() async throws {
        let transport = StubTransport([
            .text(loginBody),
            .status(401, body: "Unauthorized"),
            .text("SID=matze/new\nAuth=matze/newtoken"),
            .json(#"{"tags":[{"id":"user/-/label/Apple","type":"folder"}]}"#),
        ])
        let client = makeClient(transport)

        let tags = try await client.tags()

        #expect(tags.count == 1)
        #expect(await transport.requestCount == 4)
        // The retry must use the *new* token, not the one that was just rejected.
        #expect(await transport.header("Authorization", at: 3) == "GoogleLogin auth=matze/newtoken")
    }

    @Test("A second 401 after re-authentication gives up rather than looping")
    func repeatedUnauthorizedGivesUp() async throws {
        let transport = StubTransport([
            .text(loginBody),
            .status(401),
            .text(loginBody),
            .status(401),
        ])
        let client = makeClient(transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.tags()
        }
        // Exactly one re-login attempt: an unbounded loop here would hammer the server forever.
        #expect(await transport.requestCount == 4)
    }

    // MARK: - Stream requests

    @Test("Stream contents request carries the expected parameters")
    func streamContentsParameters() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.streamContents(.readingList, count: 100, order: .newestFirst)

        let url = await transport.urls[1]
        #expect(url.contains("/stream/contents/user/-/state/com.google/reading-list"))
        let query = await transport.queryItems(at: 1)
        #expect(query["output"] == "json")
        #expect(query["n"] == "100")
        #expect(query["r"] == "d")
        // No continuation on the first page: sending `c=0` would be a different request.
        #expect(query["c"] == nil)
    }

    @Test("A continuation is sent as c, and placeholder values are omitted", arguments: [
        (String?.some("1685680000000000"), String?.some("1685680000000000")),
        (String?.some("0"), String?.none),
        (String?.some(""), String?.none),
        (String?.none, String?.none),
    ])
    func continuationIsSentWhenMeaningful(continuation: String?, expected: String?) async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.streamContents(continuation: continuation)

        #expect(await transport.queryItems(at: 1)["c"] == expected)
    }

    @Test("A single feed stream addresses that feed")
    func feedStreamAddressesFeed() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.streamContents(.feed("feed/12"))

        #expect(await transport.urls[1].contains("/stream/contents/feed/12"))
    }

    @Test("Item ids request passes the stream as s")
    func itemIDsPassesStreamParameter() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"itemRefs":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.itemIDs(count: 1_000)

        let query = await transport.queryItems(at: 1)
        #expect(query["s"] == "user/-/state/com.google/reading-list")
        #expect(query["n"] == "1000")
    }

    /// The endpoint reads `$_POST['i']` and has no GET form, so the ids must go in the body as a
    /// repeated parameter.
    @Test("Fetching items by id posts a repeated i parameter in decimal")
    func itemsByIDPostsRepeatedParameter() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.items(ids: [GReaderItemID(value: 10), GReaderItemID(value: 1_685_681_150_315_536)])

        #expect(await transport.requests[1].httpMethod == "POST")
        #expect(await transport.body(at: 1) == "i=10&i=1685681150315536")
    }

    @Test("Fetching zero items makes no request at all")
    func emptyIDListSkipsRequest() async throws {
        let transport = StubTransport([])
        let client = makeClient(transport)

        let page = try await client.items(ids: [])

        #expect(page.items.isEmpty)
        // Not even a login: an empty batch is a no-op, and reconciliation hits this whenever the
        // local store is already up to date.
        #expect(await transport.requestCount == 0)
    }

    @Test("Subscriptions decode through the client")
    func subscriptionsDecodeThroughClient() async throws {
        let json = """
        {"subscriptions":[{"id":"feed/1","title":"F","categories":[{"id":"user/-/label/A","label":"A"}],"iconUrl":""}]}
        """
        let transport = StubTransport([.text(loginBody), .json(json)])
        let client = makeClient(transport)

        let subscriptions = try await client.subscriptions()

        #expect(subscriptions.count == 1)
        #expect(subscriptions[0].folderName == "A")
        #expect(subscriptions[0].iconURLString == nil)
    }

    /// Pointing at a reverse proxy or a login page returns HTML with a 200. A key-not-found error
    /// about JSON the user never saw is useless; naming the real problem is not.
    @Test("An HTML response to a JSON endpoint is reported as unexpected, not as a decode error")
    func htmlResponseIsReportedClearly() async throws {
        let transport = StubTransport([.text(loginBody), .text("<html>502 Bad Gateway</html>")])
        let client = makeClient(transport)

        do {
            _ = try await client.subscriptions()
            Issue.record("expected a failure")
        } catch let error as GReaderError {
            guard case .unexpectedResponse = error else {
                Issue.record("expected .unexpectedResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - output=json

    /// FreshRSS answers **501 Not Implemented** to any of these without `output=json`, so a missing
    /// one is not a soft failure — it is a feed list that can never load. Three endpoints shipped
    /// without it, and every existing test passed anyway because a stub transport does not care
    /// what the query string says. This is the test that would have caught it.
    @Test("Every JSON endpoint asks for JSON")
    func endpointsRequestJSONOutput() async throws {
        let transport = StubTransport(
            [.text(loginBody)],
            fallback: .json(#"{"subscriptions":[],"tags":[],"items":[],"itemRefs":[]}"#)
        )
        let client = makeClient(transport)

        _ = try await client.userInfo()
        _ = try await client.subscriptions()
        _ = try await client.tags()
        _ = try await client.streamContents()
        _ = try await client.itemIDs()

        let urls = await transport.urls
        // The login call is first and takes no `output`; everything after it must.
        for url in urls.dropFirst() {
            #expect(url.contains("output=json"), "\(url) would return 501")
        }
        #expect(urls.count == 6)
    }

    @Test("output is not sent twice when the caller already supplied it")
    func outputIsNotDuplicated() async throws {
        let transport = StubTransport([.text(loginBody), .json(#"{"items":[]}"#)])
        _ = try await makeClient(transport).streamContents()

        let url = try #require(await transport.urls.last)
        #expect(url.components(separatedBy: "output=json").count == 2)
    }
}
