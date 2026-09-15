import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

@Suite("Mastodon conversations")
struct MastodonContextTests {

    private func makeClient(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "token",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    /// One status, as the instance sends it.
    private func statusJSON(
        id: String,
        content: String,
        inReplyTo: String? = nil,
        replies: Int = 0,
        reblogs: Int = 0,
        favourites: Int = 0
    ) -> String {
        """
        {
          "id": "\(id)",
          "uri": "https://mastodon.social/users/a/statuses/\(id)",
          "created_at": "2026-09-01T10:00:00.000Z",
          "content": "<p>\(content)</p>",
          "visibility": "public",
          "sensitive": false,
          "spoiler_text": "",
          "media_attachments": [],
          "in_reply_to_id": \(inReplyTo.map { "\"\($0)\"" } ?? "null"),
          "in_reply_to_account_id": null,
          "url": "https://mastodon.social/@a/\(id)",
          "poll": null,
          "card": null,
          "emojis": [],
          "tags": [],
          "mentions": [],
          "replies_count": \(replies),
          "reblogs_count": \(reblogs),
          "favourites_count": \(favourites),
          "edited_at": null,
          "language": "en",
          "account": {
            "id": "1",
            "username": "a",
            "acct": "a",
            "display_name": "Ada",
            "avatar": "https://example.com/a.png",
            "avatar_static": "https://example.com/a.png",
            "url": "https://mastodon.social/@a",
            "bot": false,
            "emojis": []
          }
        }
        """
    }

    @Test("A conversation decodes into what came before and after")
    func decodesContext() async throws {
        let json = """
        {
          "ancestors": [\(statusJSON(id: "1", content: "The root")),
                        \(statusJSON(id: "2", content: "A reply", inReplyTo: "1"))],
          "descendants": [\(statusJSON(id: "4", content: "A later reply", inReplyTo: "3"))]
        }
        """

        let transport = StubTransport([.json(json)])
        let client = makeClient(transport)

        let context = try await client.context(of: MastodonStatusID("3"))

        #expect(context.ancestors.map(\.id.rawValue) == ["1", "2"])
        #expect(context.descendants.map(\.id.rawValue) == ["4"])
        // Ancestors arrive oldest first, which is what lets them be rendered in order as a
        // conversation arriving at the post being read.
        #expect(context.ancestors.first?.inReplyToId == nil)
    }

    @Test("The request goes to the status's own context path")
    func requestsTheRightPath() async throws {
        let transport = StubTransport([.json(#"{"ancestors":[],"descendants":[]}"#)])
        let client = makeClient(transport)

        _ = try await client.context(of: MastodonStatusID("109912345"))

        #expect(await transport.urls == [
            "https://mastodon.social/api/v1/statuses/109912345/context",
        ])
        #expect(await transport.header("Authorization", at: 0) == "Bearer token")
    }

    @Test("An empty conversation is not an error")
    func emptyContext() async throws {
        let transport = StubTransport([.json(#"{"ancestors":[],"descendants":[]}"#)])
        let client = makeClient(transport)

        let context = try await client.context(of: MastodonStatusID("1"))

        // A post with no replies is the common case, not a failure — the detail view shows "No
        // replies" for it rather than an error.
        #expect(context.ancestors.isEmpty)
        #expect(context.descendants.isEmpty)
    }
}
