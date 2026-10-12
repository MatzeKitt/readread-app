import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// The walk behind a reply subscription: one conversation, fetched whole, its replies written into
/// the home timeline and marked with the subscription.
///
/// What these pin is mostly what it must *not* do: skip a reply that arrives late with an old id,
/// write a reply twice, or bring back one the cache has pruned.
@Suite("Reply subscription walk")
struct ReplySubscriptionWalkTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!
    private let subscriptionID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

    private var streamKey: String { ReplySubscription.streamKey(for: subscriptionID) }

    private func statusJSON(
        id: String,
        inReplyTo: String? = nil,
        author: String = "stranger",
        createdAt: String = "2026-09-03T10:00:00.000Z"
    ) -> String {
        """
        {
            "id": "\(id)",
            "uri": "https://other.example/users/\(author)/statuses/\(id)",
            "created_at": "\(createdAt)",
            "content": "<p>Reply \(id).</p>",
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

    private func context(ancestors: [String] = [], descendants: [String]) -> StubTransport.Response {
        .json(#"{"ancestors":[\#(ancestors.joined(separator: ","))],"descendants":[\#(descendants.joined(separator: ","))]}"#)
    }

    private func makePlanner(_ transport: StubTransport, sink: RecordingIngestSink) -> MastodonIngestPlanner {
        let client = MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "tok",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        return MastodonIngestPlanner(client: client, sink: sink, accountID: accountID)
    }

    private func itemID(_ statusID: String) -> String {
        SourceIdentifier.mastodonItem(accountID: accountID, statusID: statusID)
    }

    // MARK: - First walk

    @Test("Replies are written into the home timeline and marked with the subscription")
    func repliesLandInHome() async throws {
        let transport = StubTransport([
            context(descendants: [
                statusJSON(id: "201", inReplyTo: "100"),
                statusJSON(id: "202", inReplyTo: "201"),
            ]),
            // The subscribed post, fetched as the parent of the direct reply: a context leaves out
            // the post it was asked about.
            .json(statusJSON(id: "100", author: "matze")),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 2)
        #expect(await transport.urls.first == "https://mastodon.social/api/v1/statuses/100/context")

        let direct = try #require(await sink.items[itemID("201")])
        #expect(direct.sourceID == SourceIdentifier.mastodonHome(accountID: accountID))
        #expect(direct.replySubscriptionID == subscriptionID)
        #expect(direct.replyParent != nil)

        // Answered by a reply in the same conversation, so no request was made for its parent.
        let nested = try #require(await sink.items[itemID("202")])
        #expect(nested.replyParent != nil)
        #expect(await transport.requestCount == 2)
    }

    @Test("The walk keeps a cursor of its own and leaves the home timeline's alone")
    func ownCursor() async throws {
        let transport = StubTransport([
            context(ancestors: [statusJSON(id: "50")], descendants: [statusJSON(id: "201", inReplyTo: "50")]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)

        _ = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(await sink.state(accountID: accountID, streamKey: streamKey).highestSeenID == "201")
        #expect(await sink.state(accountID: accountID, streamKey: MastodonIngestPlanner.homeStreamKey) == .fresh)
    }

    /// An empty conversation still completes a run. Left empty, the cursor would read as "never
    /// walked", and the first reply to arrive afterwards would be treated as part of a first walk —
    /// which is what decides that nothing in it can have arrived late.
    @Test("A conversation with no replies yet still records a completed run")
    func emptyConversationCompletes() async throws {
        let transport = StubTransport([context(descendants: [])])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 0)
        #expect(!(await sink.state(accountID: accountID, streamKey: streamKey).highestSeenID.isEmpty))
    }

    // MARK: - Later walks

    @Test("A later walk writes only the replies it has not seen")
    func onlyNewReplies() async throws {
        let transport = StubTransport([
            context(descendants: [
                statusJSON(id: "201", inReplyTo: "100"),
                statusJSON(id: "203", inReplyTo: "201"),
            ]),
        ])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "201"),
            accountID: accountID,
            streamKey: streamKey
        )

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(outcome.itemsWritten == 1)
        #expect(await sink.committedIDs == [itemID("203")])
        #expect(await sink.state(accountID: accountID, streamKey: streamKey).highestSeenID == "201,203")
    }

    /// The case a stop line gets wrong. An instance mints a remote post's id from when it was
    /// written, so a reply that federates late carries an id *below* replies that were seen before
    /// it — and a walk that stopped at the newest id it knew would never write it.
    @Test("A reply that arrives late with an older id is still written")
    func lateReplyWithOlderID() async throws {
        let transport = StubTransport([
            context(descendants: [
                statusJSON(id: "150", inReplyTo: "100"),
                statusJSON(id: "201", inReplyTo: "100"),
            ]),
            .json(statusJSON(id: "100", author: "matze")),
        ])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "201"),
            accountID: accountID,
            streamKey: streamKey
        )

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(outcome.itemsWritten == 1)
        #expect(await sink.committedIDs == [itemID("150")])
    }

    // MARK: - Bounds

    @Test("Replies older than the history window are neither written nor remembered")
    func historyWindow() async throws {
        let transport = StubTransport([
            context(descendants: [
                statusJSON(id: "201", inReplyTo: "100", createdAt: "2026-08-01T10:00:00.000Z"),
                statusJSON(id: "202", inReplyTo: "201", createdAt: "2026-09-02T10:00:00.000Z"),
            ]),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)
        let now = try Date("2026-09-03T12:00:00Z", strategy: .iso8601)

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID,
            historyWindowDays: 7,
            now: now
        )

        #expect(outcome.itemsWritten == 1)
        #expect(await sink.committedIDs == [itemID("202")])
        // Not remembered, so widening the window later brings it in.
        #expect(await sink.state(accountID: accountID, streamKey: streamKey).highestSeenID == "202")
    }

    @Test("A post that has gone completes the run without writing anything")
    func deletedPost() async throws {
        let transport = StubTransport([.status(404)])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "201"),
            accountID: accountID,
            streamKey: streamKey
        )

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID
        )

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 0)
        // What it had seen stays seen, so nothing comes back if the post does.
        #expect(await sink.state(accountID: accountID, streamKey: streamKey).highestSeenID == "201")
    }

    @Test("A server error is thrown for the caller to report")
    func serverError() async throws {
        let transport = StubTransport([.status(500)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)

        await #expect(throws: (any Error).self) {
            _ = try await makePlanner(transport, sink: sink).ingestReplies(
                to: MastodonStatusID("100"),
                subscriptionID: subscriptionID
            )
        }
        #expect(await sink.committedIDs.isEmpty)
    }

    @Test("Without time left, nothing is asked for")
    func outOfBudget() async throws {
        let transport = StubTransport([])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: streamKey)

        let outcome = try await makePlanner(transport, sink: sink).ingestReplies(
            to: MastodonStatusID("100"),
            subscriptionID: subscriptionID,
            budget: IngestBudget(maxPages: 5, hasTimeRemaining: { false })
        )

        #expect(outcome.stoppedForBudget)
        #expect(!outcome.isComplete)
        #expect(await transport.requestCount == 0)
    }

    // MARK: - Seen ids

    @Test("Remembered ids survive the round trip through the cursor")
    func seenIDsRoundTrip() {
        let ids: Set<String> = ["110862239481737389", "201", "9"]
        #expect(MastodonIngestPlanner.decodeSeenIDs(MastodonIngestPlanner.encodeSeenIDs(ids)) == ids)
        #expect(MastodonIngestPlanner.decodeSeenIDs(MastodonIngestPlanner.encodeSeenIDs([])).isEmpty)
        #expect(!MastodonIngestPlanner.encodeSeenIDs([]).isEmpty)
    }
}
