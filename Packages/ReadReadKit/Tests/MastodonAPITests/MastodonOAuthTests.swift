import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

@Suite("MastodonOAuth")
struct MastodonOAuthTests {

    private let instanceURL = URL(string: "https://mastodon.social")!

    private func makeOAuth(_ transport: StubTransport) -> MastodonOAuth {
        MastodonOAuth(
            instanceURL: instanceURL,
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    private let credentials = MastodonClientCredentials(
        clientID: "cid",
        clientSecret: "csecret",
        scopes: MastodonOAuth.scopes
    )

    // MARK: - Scopes

    /// Every scope the app asks for, listed out.
    ///
    /// This test used to assert that *no* scope began with anything but `read`, which was the right
    /// guard while the app only read. Liking and boosting are writes, so that assertion had to go —
    /// and it is replaced with a tighter one rather than a weaker one: the set is pinned exactly, so
    /// widening the grant by so much as one scope fails here and has to be argued for.
    ///
    /// The three still ruled out are the ones that would let the app act on the reader's *identity*
    /// rather than on a post: following, blocking and reporting (`write:follows`, `write:blocks`,
    /// `write:reports`), the blanket `write`, and push. Note what this cannot rule out:
    /// `write:statuses` is the only scope Mastodon offers for boosting and it also permits posting,
    /// so the grant is wider than the feature. That is a property of the API, and it is documented
    /// at ``MastodonOAuth/scopes``.
    @Test("The scope set is exactly what the features need")
    func scopeSetIsExact() {
        let scopes = Set(MastodonOAuth.scopes.split(separator: " ").map(String.init))

        #expect(scopes == [
            "read:statuses",
            "read:accounts",
            "read:lists",
            "read:bookmarks",
            "read:favourites",
            "read:search",
            "write:favourites",
            "write:statuses",
        ])

        // Spelled out separately from the equality above, because these are the ones whose absence
        // is a promise about what the token cannot do — and a failure here should read as that
        // promise breaking rather than as a list needing an update.
        #expect(!scopes.contains("write"))
        #expect(!scopes.contains("read"))
        #expect(!scopes.contains { $0.hasPrefix("write:follow") })
        #expect(!scopes.contains { $0.hasPrefix("write:block") })
        #expect(!scopes.contains { $0.hasPrefix("write:report") })
        #expect(!MastodonOAuth.scopes.contains("follow"))
        #expect(!MastodonOAuth.scopes.contains("push"))
    }

    // MARK: - Registration

    @Test("Registration posts the documented fields")
    func registrationPostsFields() async throws {
        let transport = StubTransport([.json("""
        {"id":"1","name":"ReadRead","client_id":"cid-abc","client_secret":"sec-xyz",
         "redirect_uris":["readread://oauth-callback"],"redirect_uri":"readread://oauth-callback"}
        """)])

        let result = try await makeOAuth(transport).register()

        #expect(result.clientID == "cid-abc")
        #expect(result.clientSecret == "sec-xyz")
        #expect(await transport.requests[0].httpMethod == "POST")
        #expect(await transport.urls[0] == "https://mastodon.social/api/v1/apps")

        let body = await transport.body(at: 0)
        #expect(body.contains("client_name=ReadRead"))
        // The custom scheme must survive percent-encoding intact, or the instance registers a
        // redirect that never matches and the callback silently never arrives.
        #expect(body.contains("redirect_uris=readread%3A%2F%2Foauth-callback"))
        #expect(body.contains("scopes=read%3Astatuses"))
    }

    // MARK: - Authorisation URL

    @Test("Authorisation URL carries the OAuth parameters")
    func authorizationURLCarriesParameters() throws {
        let (url, state) = try makeOAuth(StubTransport([])).authorizationURL(credentials: credentials)
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        #expect(url.path == "/oauth/authorize")
        #expect(query["client_id"] == "cid")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == MastodonOAuth.redirectURI)
        #expect(query["scope"] == MastodonOAuth.scopes)
        #expect(query["state"] == state)
        #expect(!state.isEmpty)
    }

    /// A predictable `state` defeats its own purpose, so it must come from the CSPRNG and differ
    /// every attempt.
    @Test("Each authorisation attempt gets a fresh, unguessable state")
    func stateIsFreshAndRandom() {
        let states = (0..<100).map { _ in MastodonOAuth.randomState() }

        #expect(Set(states).count == 100)
        // 32 random bytes, base64url without padding.
        #expect(states.allSatisfy { $0.count >= 40 })
        #expect(states.allSatisfy { !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })
    }

    // MARK: - Callback handling

    @Test("The authorisation code is read from the callback")
    func readsAuthorizationCode() throws {
        let url = URL(string: "readread://oauth-callback?code=abc123&state=xyz")!

        #expect(try MastodonOAuth.authorizationCode(fromCallback: url, expectedState: "xyz") == "abc123")
    }

    /// Without the `state` check, a crafted callback could hand the app a code belonging to an
    /// account the user never chose, and the app would exchange it without noticing.
    @Test("A mismatched state is rejected")
    func mismatchedStateRejected() {
        let url = URL(string: "readread://oauth-callback?code=abc123&state=attacker")!

        #expect(throws: MastodonError.self) {
            try MastodonOAuth.authorizationCode(fromCallback: url, expectedState: "expected")
        }
    }

    @Test("A missing state is rejected")
    func missingStateRejected() {
        let url = URL(string: "readread://oauth-callback?code=abc123")!

        #expect(throws: MastodonError.self) {
            try MastodonOAuth.authorizationCode(fromCallback: url, expectedState: "expected")
        }
    }

    /// Pressing Cancel is a normal outcome, and the instance's own message is more useful than
    /// "no code was returned".
    @Test("A denial reports the server's reason")
    func denialReportsReason() {
        let url = URL(string: "readread://oauth-callback?error=access_denied&error_description=The%20user%20denied%20access&state=xyz")!

        do {
            _ = try MastodonOAuth.authorizationCode(fromCallback: url, expectedState: "xyz")
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .authorizationFailed(let message) = error else {
                Issue.record("expected .authorizationFailed, got \(error)")
                return
            }
            #expect(message == "The user denied access")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A callback with no code is rejected")
    func missingCodeRejected() {
        let url = URL(string: "readread://oauth-callback?state=xyz")!

        #expect(throws: MastodonError.self) {
            try MastodonOAuth.authorizationCode(fromCallback: url, expectedState: "xyz")
        }
    }

    // MARK: - Token exchange

    @Test("Token exchange posts the grant and returns the token")
    func tokenExchangePostsGrant() async throws {
        let transport = StubTransport([.json("""
        {"access_token":"tok-123","token_type":"Bearer","scope":"read:statuses","created_at":1788000000}
        """)])

        let token = try await makeOAuth(transport).exchange(code: "the-code", credentials: credentials)

        #expect(token == "tok-123")
        #expect(await transport.urls[0] == "https://mastodon.social/oauth/token")

        let body = await transport.body(at: 0)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=the-code"))
        #expect(body.contains("client_secret=csecret"))
    }

    /// `.urlQueryAllowed` would let `+`, `&` and `=` through unencoded, and a client secret
    /// containing `+` would arrive as a space — failing with a misleading "invalid client".
    @Test("Form-significant characters in secrets are percent-encoded")
    func encodesAwkwardSecrets() async throws {
        let transport = StubTransport([.json(#"{"access_token":"t","token_type":"Bearer","scope":"read"}"#)])
        let awkward = MastodonClientCredentials(
            clientID: "id+with/chars",
            clientSecret: "p+q&r=s",
            scopes: MastodonOAuth.scopes
        )

        _ = try await makeOAuth(transport).exchange(code: "c", credentials: awkward)

        let body = await transport.body(at: 0)
        #expect(body.contains("client_secret=p%2Bq%26r%3Ds"))
        #expect(body.contains("client_id=id%2Bwith%2Fchars"))
    }

    // MARK: - Adding a second account on the same instance

    /// The fix for a bug worth writing down: on an instance the reader was already signed in to,
    /// authorising showed *nothing at all* and handed back a code for the account already logged
    /// in — so "add another account" produced a duplicate of the first one. Mastodon documents
    /// `force_login` for exactly this.
    @Test("A second account on the same instance forces the login form")
    func secondAccountForcesLogin() throws {
        let url = try makeOAuth(StubTransport())
            .authorizationURL(credentials: credentials, forcesLogin: true)
            .url

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(query["force_login"] == "true")
    }

    /// Absent by default, and that is not laziness. For a first account the skip is the desirable
    /// behaviour: somebody already signed in to their instance should not have to type a password
    /// to add their own feed reader.
    @Test("A first account does not")
    func firstAccountDoesNotForceLogin() throws {
        let url = try makeOAuth(StubTransport()).authorizationURL(credentials: credentials).url

        #expect(!url.absoluteString.contains("force_login"))
    }

    /// Everything else about the request has to survive the extra parameter — the `state` above
    /// all, since it is what stops a crafted callback handing the app somebody else's code.
    @Test("Forcing the login form changes nothing else about the request")
    func forcingLoginKeepsTheRestOfTheRequest() throws {
        let oauth = makeOAuth(StubTransport())
        let forced = try oauth.authorizationURL(credentials: credentials, forcesLogin: true)

        let components = try #require(URLComponents(url: forced.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.path == "/oauth/authorize")
        #expect(query["client_id"] == "cid")
        #expect(query["redirect_uri"] == MastodonOAuth.redirectURI)
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == MastodonOAuth.scopes)
        #expect(query["state"] == forced.state)
        #expect(!forced.state.isEmpty)
    }
}
