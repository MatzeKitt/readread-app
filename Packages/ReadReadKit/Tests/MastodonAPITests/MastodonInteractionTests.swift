import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// The four write endpoints, and the failures that decide what the reader is told.
///
/// These are the only requests in the app that change something on somebody else's server, so what
/// they send and how they read the answer back is worth pinning rather than inspecting.
@Suite("Mastodon favourite and boost")
struct MastodonInteractionTests {

    private func makeClient(_ transport: StubTransport, token: String? = "tok") -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: token,
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    /// A post as the server returns it after a favourite.
    private func statusJSON(
        id: String = "110",
        favourited: Bool = true,
        reblogged: Bool = false,
        favouritesCount: Int = 4,
        reblogsCount: Int = 2
    ) -> String {
        """
        {"id":"\(id)","uri":"https://mastodon.social/users/a/statuses/\(id)",
         "created_at":"2026-09-01T09:00:00.000Z",
         "account":{"id":"1","username":"a","acct":"a","display_name":"A","avatar":"https://x/a.png","url":"https://mastodon.social/@a","emojis":[]},
         "content":"<p>Hello.</p>","visibility":"public","sensitive":false,"spoiler_text":"",
         "media_attachments":[],"emojis":[],"tags":[],"mentions":[],
         "replies_count":1,"reblogs_count":\(reblogsCount),"favourites_count":\(favouritesCount),
         "favourited":\(favourited),"reblogged":\(reblogged)}
        """
    }

    // MARK: - Paths

    @Test("Favouriting and unfavouriting post to the documented paths", arguments: [
        (true, "favourite"),
        (false, "unfavourite"),
    ])
    func favouritePaths(isOn: Bool, path: String) async throws {
        let transport = StubTransport(.json(statusJSON(favourited: isOn)))
        _ = try await makeClient(transport).favourite(MastodonStatusID("110"), isOn: isOn)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/statuses/110/\(path)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("Boosting and unboosting post to the documented paths", arguments: [
        (true, "reblog"),
        (false, "unreblog"),
    ])
    func reblogPaths(isOn: Bool, path: String) async throws {
        let transport = StubTransport(.json(statusJSON(reblogged: isOn)))
        _ = try await makeClient(transport).reblog(MastodonStatusID("110"), isOn: isOn)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/statuses/110/\(path)")
    }

    // MARK: - Reading the answer back

    @Test("The updated post carries the counts and the flag")
    func updatedPostCarriesState() async throws {
        let transport = StubTransport(.json(statusJSON(favourited: true, favouritesCount: 5)))
        let status = try await makeClient(transport).favourite(MastodonStatusID("110"), isOn: true)

        #expect(status.favourited == true)
        #expect(status.favouritesCount == 5)
    }

    /// The case that would blank a row on success.
    ///
    /// Boosting answers with the *wrapper* the server has just created. Its own counts are zero and
    /// its own flags describe the boost, so anything reading the outer status writes "0 boosts, 0
    /// favourites" onto a post that has just gained one.
    @Test("A boost's own counts are zero and the post's are on the inner status")
    func boostWrapperCarriesTheInnerStatus() async throws {
        let inner = statusJSON(id: "110", favourited: true, reblogged: true, favouritesCount: 9, reblogsCount: 3)
        let wrapper = """
        {"id":"999","uri":"https://mastodon.social/users/me/statuses/999",
         "created_at":"2026-09-02T10:00:00.000Z",
         "account":{"id":"2","username":"me","acct":"me","display_name":"Me","avatar":"https://x/m.png","url":"https://mastodon.social/@me","emojis":[]},
         "content":"","visibility":"public","sensitive":false,"spoiler_text":"",
         "media_attachments":[],"emojis":[],"tags":[],"mentions":[],
         "replies_count":0,"reblogs_count":0,"favourites_count":0,
         "reblog":\(inner)}
        """

        let transport = StubTransport(.json(wrapper))
        let status = try await makeClient(transport).reblog(MastodonStatusID("110"), isOn: true)

        #expect(status.reblogsCount == 0)
        #expect(status.displayStatus.reblogsCount == 3)
        #expect(status.displayStatus.favouritesCount == 9)
        #expect(status.displayStatus.reblogged == true)
    }

    // MARK: - Failures

    /// The failure every reader hits first after this feature ships: the token they already have
    /// was granted before the app asked for write scopes.
    @Test("A refused write is a scope problem, not a dead token")
    func refusedWriteIsAScopeProblem() async throws {
        let transport = StubTransport(.status(403, body: #"{"error":"This action is outside the authorized scopes"}"#))

        do {
            _ = try await makeClient(transport).favourite(MastodonStatusID("110"), isOn: true)
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .writeNotAuthorized = error else {
                Issue.record("expected .writeNotAuthorized, got \(error)")
                return
            }
        }
    }

    @Test("A 401 on a write is still a dead token")
    func unauthorizedWriteIsARevokedToken() async throws {
        let transport = StubTransport(.status(401))

        do {
            _ = try await makeClient(transport).favourite(MastodonStatusID("110"), isOn: true)
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .tokenRevoked = error else {
                Issue.record("expected .tokenRevoked, got \(error)")
                return
            }
        }
    }

    /// Deliberate asymmetry, pinned so it is not "tidied" later. On a read, a 403 and a 401 have
    /// the same answer — every `read:` scope has been in the set from the first version, so a
    /// refused read is not a scope the app forgot to ask for.
    @Test("A 403 on a read is still reported as a revoked token")
    func forbiddenReadIsStillRevoked() async throws {
        let transport = StubTransport(.status(403))

        do {
            _ = try await makeClient(transport).homeTimeline()
            Issue.record("expected a failure")
        } catch let error as MastodonError {
            guard case .tokenRevoked = error else {
                Issue.record("expected .tokenRevoked, got \(error)")
                return
            }
        }
    }

    // MARK: - Cross-account resolution

    @Test("Resolving asks the acting instance to go and fetch the post")
    func resolveAsksTheInstanceToFetch() async throws {
        let transport = StubTransport(.json(#"{"statuses":[\#(statusJSON(id: "555"))],"accounts":[],"hashtags":[]}"#))
        let resolved = try await makeClient(transport)
            .resolveStatus(url: URL(string: "https://other.example/@someone/123")!)

        #expect(resolved?.id.rawValue == "555")

        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.path == "/api/v2/search")
        #expect(query["q"] == "https://other.example/@someone/123")
        // Without this the endpoint only searches what the instance has already indexed, which for
        // a post nobody there follows is nothing.
        #expect(query["resolve"] == "true")
        #expect(query["type"] == "statuses")
    }

    @Test("An instance that will not resolve the post says so with an empty list")
    func resolveReturnsNilWhenNothingFound() async throws {
        let transport = StubTransport(.json(#"{"statuses":[],"accounts":[],"hashtags":[]}"#))
        let resolved = try await makeClient(transport)
            .resolveStatus(url: URL(string: "https://other.example/@someone/123")!)

        #expect(resolved == nil)
    }

    /// A boost resolved on another instance must act on the post, not on the boost.
    @Test("Resolving reads through a boost wrapper")
    func resolveReadsThroughABoost() async throws {
        let inner = statusJSON(id: "777")
        let wrapper = """
        {"id":"888","uri":"https://other.example/users/x/statuses/888",
         "created_at":"2026-09-02T10:00:00.000Z",
         "account":{"id":"3","username":"x","acct":"x","display_name":"X","avatar":"https://x/x.png","url":"https://other.example/@x","emojis":[]},
         "content":"","visibility":"public","sensitive":false,"spoiler_text":"",
         "media_attachments":[],"emojis":[],"tags":[],"mentions":[],
         "replies_count":0,"reblogs_count":0,"favourites_count":0,
         "reblog":\(inner)}
        """
        let transport = StubTransport(.json(#"{"statuses":[\#(wrapper)],"accounts":[],"hashtags":[]}"#))
        let resolved = try await makeClient(transport)
            .resolveStatus(url: URL(string: "https://other.example/@someone/123")!)

        #expect(resolved?.displayStatus.id.rawValue == "777")
    }
}
