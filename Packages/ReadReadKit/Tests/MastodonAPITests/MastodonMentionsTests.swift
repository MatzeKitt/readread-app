import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// Replies and mentions from people the reader does not follow reach an account as notifications
/// and nowhere else. These pin the walk that brings them into the home timeline: that it pages by
/// notification ids on a stream of its own, and that what it writes is indistinguishable from the
/// same post arriving through the home timeline.
@Suite("Mastodon mentions")
struct MastodonMentionsTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    private func statusJSON(id: String, inReplyTo: String? = nil, author: String = "stranger") -> String {
        """
        {
            "id": "\(id)",
            "uri": "https://other.example/users/\(author)/statuses/\(id)",
            "created_at": "2026-09-03T10:00:00.000Z",
            "content": "<p>@matze Reply \(id).</p>",
            "visibility": "public",
            "sensitive": false,
            "spoiler_text": "",
            "media_attachments": [],
            "reblog": null,
            "in_reply_to_id": \(inReplyTo.map { "\"\($0)\"" } ?? "null"),
            "in_reply_to_account_id": \(inReplyTo == nil ? "null" : "\"1\""),
            "url": "https://other.example/@\(author)/\(id)",
            "poll": null,
            "card": null,
            "emojis": [],
            "tags": [],
            "mentions": [],
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "language": "en",
            "account": {
                "id": "77",
                "username": "\(author)",
                "acct": "\(author)@other.example",
                "display_name": "Someone",
                "avatar": "https://files.example/s.png",
                "avatar_static": "https://files.example/s.png",
                "url": "https://other.example/@\(author)",
                "bot": false,
                "emojis": []
            }
        }
        """
    }

    private func notificationJSON(id: String, type: String = "mention", status: String?) -> String {
        """
        {
            "id": "\(id)",
            "type": "\(type)",
            "created_at": "2026-09-03T10:00:00.000Z",
            "status": \(status ?? "null")
        }
        """
    }

    private func page(_ notifications: [String], nextMaxID: String? = nil) -> StubTransport.Response {
        let headers = nextMaxID.map {
            ["Link": "<https://mastodon.social/api/v1/notifications?max_id=\($0)>; rel=\"next\""]
        } ?? [:]
        return .statusWithHeaders(200, headers: headers, body: "[\(notifications.joined(separator: ","))]")
    }

    private func makeClient(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "tok",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    private func makePlanner(_ transport: StubTransport, sink: RecordingIngestSink) -> MastodonIngestPlanner {
        MastodonIngestPlanner(client: makeClient(transport), sink: sink, accountID: accountID, pageSize: 3)
    }

    // MARK: - Request

    @Test("Mentions are asked for by type, at the maximum page size")
    func requestShape() async throws {
        let transport = StubTransport([page([]), page([])])
        let client = makeClient(transport)

        _ = try await client.mentionNotifications()
        _ = try await client.mentionNotifications(maxID: "900")

        let urls = await transport.urls
        #expect(urls[0].hasPrefix("https://mastodon.social/api/v1/notifications?"))
        let first = await transport.queryItems(at: 0)
        #expect(first["types[]"] == "mention")
        #expect(first["limit"] == "40")
        #expect(first["max_id"] == nil)
        #expect(await transport.queryItems(at: 1)["max_id"] == "900")
    }

    /// The token predates `read:notifications`. Reporting that as revoked would be untrue — the
    /// home timeline still loads with it — and would send the reader looking for a sign-out.
    @Test("A refused notifications read is a missing scope, not a dead token")
    func forbiddenIsMissingScope() async throws {
        do {
            _ = try await makeClient(StubTransport(.status(403))).mentionNotifications()
            Issue.record("Expected the read to be refused")
        } catch let error as MastodonError {
            guard case .notificationsNotAuthorized = error else {
                Issue.record("Expected .notificationsNotAuthorized, got \(error)")
                return
            }
        }
    }

    @Test("A 401 on notifications is still a dead token")
    func unauthorizedIsRevoked() async throws {
        do {
            _ = try await makeClient(StubTransport(.status(401))).mentionNotifications()
            Issue.record("Expected the read to be refused")
        } catch let error as MastodonError {
            guard case .tokenRevoked = error else {
                Issue.record("Expected .tokenRevoked, got \(error)")
                return
            }
        }
    }

    // MARK: - Walk

    @Test("A mention is written into the home timeline under the post's own id")
    func mentionLandsInHome() async throws {
        let transport = StubTransport([
            page([notificationJSON(id: "500", status: statusJSON(id: "111"))]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "mentions")

        let outcome = try await makePlanner(transport, sink: sink).ingestMentions()

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 1)

        // The status id, never the notification's: the same post arriving through the home
        // timeline must land on this same row.
        let itemID = SourceIdentifier.mastodonItem(accountID: accountID, statusID: "111")
        let item = try #require(await sink.items[itemID])
        #expect(item.sourceID == SourceIdentifier.mastodonHome(accountID: accountID))
        #expect(item.authorHandle == "stranger@other.example")
        #expect(item.providerID == "111")
    }

    /// Notification ids and status ids are separate sequences. Stopping the mentions walk by a
    /// status id would compare unrelated numbers, and sharing the home stream's cursor would make
    /// each walk's stop line wrong for the other.
    @Test("The walk keeps its own stop line, in notification ids")
    func ownStopLine() async throws {
        let transport = StubTransport([
            page([
                notificationJSON(id: "502", status: statusJSON(id: "113")),
                notificationJSON(id: "501", status: statusJSON(id: "112")),
            ]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "mentions")

        _ = try await makePlanner(transport, sink: sink).ingestMentions()

        #expect(await sink.state(accountID: accountID, streamKey: "mentions").highestSeenID == "502")
        #expect(await sink.state(accountID: accountID, streamKey: "home") == .fresh)
    }

    @Test("A later walk stops at the newest notification it already has")
    func stopsAtKnownNotification() async throws {
        let transport = StubTransport([
            page([
                notificationJSON(id: "504", status: statusJSON(id: "115")),
                notificationJSON(id: "502", status: statusJSON(id: "113")),
                notificationJSON(id: "501", status: statusJSON(id: "112")),
            ], nextMaxID: "501"),
        ])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "502"),
            accountID: accountID,
            streamKey: "mentions"
        )

        let outcome = try await makePlanner(transport, sink: sink).ingestMentions()

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 1)
        #expect(await transport.requestCount == 1)
        #expect(await sink.state(accountID: accountID, streamKey: "mentions").highestSeenID == "504")
    }

    /// An instance older than `types[]` ignores it and answers with every kind. A favourite's
    /// status is the reader's own post, which must not be written as though somebody had replied.
    @Test("Only mentions are written, and the rest still move the cursor")
    func onlyMentionsAreWritten() async throws {
        let transport = StubTransport([
            page([
                notificationJSON(id: "505", type: "favourite", status: statusJSON(id: "1", author: "matze")),
                notificationJSON(id: "504", status: nil),
                notificationJSON(id: "503", status: statusJSON(id: "114")),
            ]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "mentions")

        let outcome = try await makePlanner(transport, sink: sink).ingestMentions()

        #expect(outcome.itemsWritten == 1)
        #expect(await sink.committedIDs == [SourceIdentifier.mastodonItem(accountID: accountID, statusID: "114")])
        #expect(await sink.state(accountID: accountID, streamKey: "mentions").highestSeenID == "505")
    }

    @Test("A page of nothing but skipped notifications does not end the walk")
    func skippedPageContinues() async throws {
        let transport = StubTransport([
            page([notificationJSON(id: "506", type: "follow", status: nil)], nextMaxID: "506"),
            page([notificationJSON(id: "505", status: statusJSON(id: "116"))]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "mentions")

        let outcome = try await makePlanner(transport, sink: sink).ingestMentions()

        #expect(outcome.pagesFetched == 2)
        #expect(outcome.itemsWritten == 1)
    }

    /// The point of the feature: a reply shows the post it answers, which for a mention is almost
    /// always the reader's own — and that post is not on the page, so it has to be fetched.
    @Test("A reply is written with the post it answers")
    func replyCarriesParent() async throws {
        let transport = StubTransport([
            page([notificationJSON(id: "500", status: statusJSON(id: "111", inReplyTo: "42"))]),
            .json(statusJSON(id: "42", author: "matze")),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "mentions")

        _ = try await makePlanner(transport, sink: sink).ingestMentions()

        let itemID = SourceIdentifier.mastodonItem(accountID: accountID, statusID: "111")
        let item = try #require(await sink.items[itemID])
        #expect(await transport.urls.last == "https://mastodon.social/api/v1/statuses/42")
        #expect(item.replyParent != nil)
        #expect(item.engagement?.inReplyToStatusID == "42")
    }
}
