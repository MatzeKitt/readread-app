import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// Profiles: the account itself, its posts, and the two lists of accounts around it.
@Suite("Mastodon profiles")
struct MastodonProfileTests {

    private func makeClient(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "token",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    /// Trimmed from what mastodon.social actually answers, keeping the two awkward parts: a
    /// `verified_at` written with a numeric offset rather than `Z`, and a last-post date with no
    /// time at all.
    private static let profileJSON = """
        {
          "id": "13179",
          "username": "Mastodon",
          "acct": "Mastodon",
          "display_name": "Mastodon",
          "locked": false,
          "bot": false,
          "created_at": "2016-11-23T00:00:00.000Z",
          "note": "<p>Our mission is to connect the world.</p>",
          "url": "https://mastodon.social/@Mastodon",
          "avatar": "https://files.mastodon.social/a.png",
          "avatar_static": "https://files.mastodon.social/a.png",
          "header": "https://files.mastodon.social/h.png",
          "header_static": "https://files.mastodon.social/h.png",
          "followers_count": 878927,
          "following_count": 51,
          "statuses_count": 565,
          "last_status_at": "2026-10-09",
          "hide_collections": false,
          "emojis": [],
          "fields": [
            {
              "name": "Homepage",
              "value": "<a href=\\"https://joinmastodon.org\\">joinmastodon.org</a>",
              "verified_at": "2018-10-31T04:11:00.076+00:00"
            },
            { "name": "Pronouns", "value": "it/its", "verified_at": null }
          ]
        }
        """

    private static let accountJSON = """
        {
          "id": "2",
          "username": "b",
          "acct": "b@example.social",
          "display_name": "",
          "avatar": "https://example.social/b.png",
          "url": "https://example.social/@b"
        }
        """

    @Test("A profile decodes, verified links and all")
    func decodesProfile() async throws {
        let transport = StubTransport([.json(Self.profileJSON)])

        let profile = try await makeClient(transport).profile("13179")

        #expect(await transport.urls == ["https://mastodon.social/api/v1/accounts/13179"])
        #expect(profile.bestDisplayName == "Mastodon")
        #expect(profile.followersCount == 878_927)
        #expect(profile.followingCount == 51)
        #expect(profile.statusesCount == 565)
        #expect(profile.headerURLString == "https://files.mastodon.social/h.png")
        #expect(!profile.isRemote)
        #expect(profile.fields?.map(\.isVerified) == [true, false])
    }

    /// Mastodon answers "no banner" with a grey placeholder, which drawn would look like a picture
    /// that never finishes loading.
    @Test("The instance's placeholder banner counts as no banner")
    func missingHeaderIsNil() throws {
        let json = Self.profileJSON
            .replacingOccurrences(of: "https://files.mastodon.social/h.png", with: "https://mastodon.social/headers/original/missing.png")
            .replacingOccurrences(of: "\"acct\": \"Mastodon\"", with: "\"acct\": \"Mastodon@mastodon.social\"")
        let profile = try JSONDecoder.mastodon.decode(MastodonProfile.self, from: Data(json.utf8))

        #expect(profile.headerURLString == nil)
        #expect(profile.isRemote)
    }

    @Test("Posts leave replies out and continue from the Link header")
    func pagesPosts() async throws {
        let transport = StubTransport([
            .statusWithHeaders(
                200,
                headers: ["Link": "<https://mastodon.social/api/v1/accounts/1/statuses?max_id=99>; rel=\"next\""],
                body: "[]"
            ),
        ])

        let page = try await makeClient(transport).accountStatuses("1", maxID: "120")

        let query = await transport.queryItems(at: 0)
        #expect(query["exclude_replies"] == "true")
        #expect(query["max_id"] == "120")
        #expect(query["limit"] == "40")
        #expect(page.nextMaxID == "99")
    }

    /// The `max_id` of a follower list is the follow's id, not an account's, so the only correct
    /// cursor is the one the server writes into the header.
    @Test("Followers and following page by the header's cursor")
    func pagesAccounts() async throws {
        let transport = StubTransport([
            .statusWithHeaders(
                200,
                headers: ["Link": "<https://mastodon.social/api/v1/accounts/1/followers?limit=80&max_id=555>; rel=\"next\", <https://mastodon.social/api/v1/accounts/1/followers?since_id=600>; rel=\"prev\""],
                body: "[\(Self.accountJSON)]"
            ),
            .json("[]"),
        ])
        let client = makeClient(transport)

        let followers = try await client.followers(of: "1")
        let following = try await client.following(of: "1", maxID: "555")

        #expect(followers.accounts.map(\.bestDisplayName) == ["@b@example.social"])
        #expect(followers.nextMaxID == "555")
        #expect(following.nextMaxID == nil)
        #expect(await transport.urls == [
            "https://mastodon.social/api/v1/accounts/1/followers?limit=80",
            "https://mastodon.social/api/v1/accounts/1/following?limit=80&max_id=555",
        ])
    }

    // MARK: - Pinned posts

    @Test("Pinned posts are asked for by flag, in one request")
    func fetchesPinned() async throws {
        let transport = StubTransport([.json("[]")])

        _ = try await makeClient(transport).pinnedStatuses("1")

        #expect(await transport.urls == ["https://mastodon.social/api/v1/accounts/1/statuses?pinned=true"])
    }

    // MARK: - Following

    private static let relationshipJSON = """
        {"id": "1", "following": true, "requested": false, "followed_by": true, "muting": false}
        """

    @Test("The relationship is looked up for the one account asked about")
    func fetchesRelationship() async throws {
        let transport = StubTransport([.json("[\(Self.relationshipJSON)]")])

        let relationship = try await makeClient(transport).relationship(with: "1")

        #expect(await transport.queryItems(at: 0)["id[]"] == "1")
        #expect(relationship?.following == true)
        #expect(relationship?.followedBy == true)
    }

    /// A token granted before following existed has no `read:follows`. That is a scope to grant,
    /// not a dead token, and calling it revoked would send the reader looking for a sign-out.
    @Test("A token without the follow scopes is told apart from a revoked one")
    func relationshipForbiddenIsAScope() async throws {
        let transport = StubTransport([.status(403)])

        do {
            _ = try await makeClient(transport).relationship(with: "1")
            Issue.record("A 403 was taken as an answer")
        } catch MastodonError.writeNotAuthorized {
            // The scope is missing, which re-authorising fixes.
        } catch {
            Issue.record("Expected writeNotAuthorized, got \(error)")
        }
    }

    @Test("Follow and unfollow post to their endpoints and read back the relationship")
    func followsAndUnfollows() async throws {
        let transport = StubTransport([
            .json(#"{"id": "1", "following": false, "requested": true}"#),
            .json(#"{"id": "1", "following": false, "requested": false}"#),
        ])
        let client = makeClient(transport)

        let requested = try await client.follow("1", isOn: true)
        let withdrawn = try await client.follow("1", isOn: false)

        #expect(requested.requested == true)
        #expect(withdrawn.requested == false)
        #expect(await transport.urls == [
            "https://mastodon.social/api/v1/accounts/1/follow",
            "https://mastodon.social/api/v1/accounts/1/unfollow",
        ])
        #expect(await transport.requests.map(\.httpMethod) == ["POST", "POST"])
    }

    // MARK: - Resolving

    @Test("An account is resolved through search, fetching it if the server has not seen it")
    func resolvesAccount() async throws {
        let transport = StubTransport([.json("{\"accounts\": [\(Self.accountJSON)], \"statuses\": [], \"hashtags\": []}")])

        let account = try await makeClient(transport).resolveAccount("https://example.social/users/b")

        let query = await transport.queryItems(at: 0)
        #expect(query["q"] == "https://example.social/users/b")
        #expect(query["resolve"] == "true")
        #expect(query["type"] == "accounts")
        #expect(account?.id == "2")
    }

    @Test("A search that finds nobody resolves to nothing")
    func resolvesNobody() async throws {
        let transport = StubTransport([.json(#"{"accounts": [], "statuses": [], "hashtags": []}"#)])

        #expect(try await makeClient(transport).resolveAccount("nobody@example.social") == nil)
    }
}
