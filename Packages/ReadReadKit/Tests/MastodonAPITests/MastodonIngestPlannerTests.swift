import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import MastodonAPI

/// The same two-cursor guarantees as the FreshRSS walk, re-proved here because the provider
/// differs in every mechanism: `Link`-header pagination instead of a continuation token, opaque
/// string ids instead of numeric ones, and no separate server-insertion timestamp.
@Suite("Mastodon sectioned ingest")
struct MastodonIngestPlannerTests {

    private let accountID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    /// Builds a timeline page whose ids descend from `startID`, with a `Link` header when there is
    /// more to fetch.
    private func page(startID: Int, count: Int, hasNext: Bool) -> StubTransport.Response {
        let statuses = (0..<count).map { offset -> String in
            let id = startID - offset
            return """
            {
                "id": "1104512345678\(id)",
                "uri": "https://mastodon.social/users/a/statuses/\(id)",
                "created_at": "2026-09-03T10:\(String(format: "%02d", offset)):00.000Z",
                "content": "<p>Post \(id).</p>",
                "visibility": "public",
                "sensitive": false,
                "spoiler_text": "",
                "media_attachments": [],
                "reblog": null,
                "in_reply_to_id": null,
                "in_reply_to_account_id": null,
                "url": "https://mastodon.social/@a/\(id)",
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
                    "id": "1",
                    "username": "a",
                    "acct": "a",
                    "display_name": "Author A",
                    "avatar": "https://files.example/a.png",
                    "avatar_static": "https://files.example/a.png",
                    "url": "https://mastodon.social/@a",
                    "bot": false,
                    "emojis": []
                }
            }
            """
        }
        let oldest = startID - count + 1
        let headers = hasNext
            ? ["Link": "<https://mastodon.social/api/v1/timelines/home?max_id=1104512345678\(oldest)>; rel=\"next\""]
            : [:]
        return .statusWithHeaders(200, headers: headers, body: "[\(statuses.joined(separator: ","))]")
    }

    private func makePlanner(
        _ transport: StubTransport,
        sink: RecordingIngestSink,
        pageSize: Int = 3
    ) -> MastodonIngestPlanner {
        let client = MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "tok",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
        return MastodonIngestPlanner(client: client, sink: sink, accountID: accountID, pageSize: pageSize)
    }

    // MARK: - Basic walk

    @Test("A first ingest walks to the end of the timeline")
    func firstIngestWalksToEnd() async throws {
        let transport = StubTransport([
            page(startID: 300, count: 3, hasNext: true),
            page(startID: 297, count: 3, hasNext: true),
            page(startID: 294, count: 2, hasNext: false),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")
        let planner = makePlanner(transport, sink: sink)

        let outcome = try await planner.ingest()

        #expect(outcome.isComplete)
        #expect(outcome.pagesFetched == 3)
        #expect(outcome.itemsWritten == 8)
        #expect(await sink.state(accountID: accountID, streamKey: "home").highestSeenID == "1104512345678300")
    }

    /// The absence of a `rel="next"` link is the only signal that there is nothing older, so it has
    /// to end the walk — otherwise it would loop on the last page forever.
    @Test("A page without a next link ends the walk")
    func missingNextLinkEndsWalk() async throws {
        let transport = StubTransport([page(startID: 300, count: 3, hasNext: false)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        let outcome = try await makePlanner(transport, sink: sink).ingest()

        #expect(outcome.isComplete)
        #expect(outcome.pagesFetched == 1)
        #expect(await transport.requestCount == 1)
    }

    @Test("The walk stops at the first already-known status")
    func stopsAtKnownStatus() async throws {
        let transport = StubTransport([page(startID: 300, count: 4, hasNext: true)])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(highestSeenID: "1104512345678298"),
            accountID: accountID,
            streamKey: "home"
        )

        let outcome = try await makePlanner(transport, sink: sink, pageSize: 4).ingest()

        #expect(outcome.isComplete)
        // 300 and 299 are new; 298 is the stop line and ends the walk.
        #expect(outcome.itemsWritten == 2)
        #expect(await transport.requestCount == 1)
    }

    @Test("An empty timeline completes cleanly")
    func emptyTimelineCompletes() async throws {
        let transport = StubTransport([.json("[]")])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        let outcome = try await makePlanner(transport, sink: sink).ingest()

        #expect(outcome.isComplete)
        #expect(outcome.itemsWritten == 0)
        #expect(await sink.state(accountID: accountID, streamKey: "home").highestSeenID.isEmpty)
    }

    // MARK: - The two-cursor guarantee

    @Test("The stop line does not move when a run is cut short")
    func stopLineDoesNotMoveOnInterruptedRun() async throws {
        let transport = StubTransport([
            page(startID: 300, count: 3, hasNext: true),
            page(startID: 297, count: 3, hasNext: true),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        let outcome = try await makePlanner(transport, sink: sink).ingest(budget: IngestBudget(maxPages: 2))

        #expect(outcome.isComplete == false)
        #expect(await sink.abandonments == 1)

        let state = await sink.state(accountID: accountID, streamKey: "home")
        // Still empty. Promoting it to 300 would make the next run stop instantly and lose
        // everything below page two, permanently and silently.
        #expect(state.highestSeenID.isEmpty)
        #expect(state.isWalkInProgress)
        #expect(state.resumeContinuation == "1104512345678295")
        #expect(state.pendingHighestSeenID == "1104512345678300")
    }

    @Test("An interrupted run resumes and yields the same statuses as an uninterrupted one")
    func resumedRunMatchesUninterruptedRun() async throws {
        let straightThrough = StubTransport([
            page(startID: 300, count: 3, hasNext: true),
            page(startID: 297, count: 3, hasNext: true),
            page(startID: 294, count: 2, hasNext: false),
        ])
        let reference = RecordingIngestSink(accountID: accountID, streamKey: "home")
        _ = try await makePlanner(straightThrough, sink: reference).ingest()
        let expected = await reference.committedIDs

        let resumed = RecordingIngestSink(accountID: accountID, streamKey: "home")

        let firstLeg = StubTransport([
            page(startID: 300, count: 3, hasNext: true),
            page(startID: 297, count: 3, hasNext: true),
        ])
        _ = try await makePlanner(firstLeg, sink: resumed).ingest(budget: IngestBudget(maxPages: 2))

        let secondLeg = StubTransport([page(startID: 294, count: 2, hasNext: false)])
        let second = try await makePlanner(secondLeg, sink: resumed).ingest()

        #expect(second.isComplete)
        // The resumed walk must ask the server to continue from exactly where it stopped.
        #expect(await secondLeg.queryItems(at: 0)["max_id"] == "1104512345678295")
        #expect(await resumed.committedIDs == expected)
        #expect(await resumed.state(accountID: accountID, streamKey: "home").highestSeenID == "1104512345678300")
    }

    @Test("A resume cursor from a completed run is ignored")
    func staleResumeCursorIsIgnored() async throws {
        let transport = StubTransport([page(startID: 300, count: 2, hasNext: false)])
        let sink = RecordingIngestSink(
            initialState: IngestCursorState(
                highestSeenID: "1104512345678100",
                resumeContinuation: "1104512345678200",
                isWalkInProgress: false,
                pendingHighestSeenID: "1104512345678250"
            ),
            accountID: accountID,
            streamKey: "home"
        )

        _ = try await makePlanner(transport, sink: sink).ingest()

        // No `max_id`: the walk must start at the newest status, not part-way down.
        #expect(await transport.queryItems(at: 0)["max_id"] == nil)
    }

    @Test("Cancellation propagates")
    func cancellationPropagates() async throws {
        let transport = StubTransport([], fallback: page(startID: 300, count: 3, hasNext: true))
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")
        let planner = makePlanner(transport, sink: sink)

        let task = Task { try await planner.ingest(budget: IngestBudget(maxPages: 1_000)) }
        task.cancel()

        await #expect(throws: (any Error).self) { try await task.value }
    }

    // MARK: - Mapping

    @Test("A status maps onto the store's shape")
    func mapsStatusFields() async throws {
        let transport = StubTransport([page(startID: 300, count: 1, hasNext: false)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        #expect(item.kind == .status)
        #expect(item.sourceID == SourceIdentifier.mastodonHome(accountID: accountID))
        #expect(item.authorName == "Author A")
        #expect(item.title == "Post 300.")
        #expect(item.iconURLString == "https://files.example/a.png")
        #expect(item.providerID == "1104512345678300")
        // Mastodon exposes no separate insertion time, so both keys come from `created_at`.
        #expect(item.sortKey == item.ingestKey)
        // The payload is stored so the detail view can render polls, emoji and media natively.
        #expect(item.mastodonPayload != nil)
    }

    @Test("The stored payload decodes back into a status")
    func storedPayloadRoundTrips() async throws {
        let transport = StubTransport([page(startID: 300, count: 1, hasNext: false)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let payload = try #require(await sink.items.values.first?.mastodonPayload)
        let decoded = try JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
        #expect(decoded.id == MastodonStatusID("1104512345678300"))
        #expect(decoded.account.displayName == "Author A")
    }

    /// A boost's own timestamp places it in the timeline, but the author and body shown are the
    /// original's. Using the inner status's timestamp would file a boost weeks in the past, where
    /// it would land below the marker and never be seen.
    @Test("A boost is ordered by its own time but shows the original's content")
    func boostOrderedByBoostTime() async throws {
        let boost = """
        [{
            "id": "1104512345678999",
            "uri": "https://mastodon.social/users/b/statuses/999/activity",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": null, "poll": null, "card": null, "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "edited_at": null, "language": null,
            "account": {
                "id": "2", "username": "booster", "acct": "booster", "display_name": "Booster",
                "avatar": "https://files.example/b.png", "avatar_static": null,
                "url": "https://mastodon.social/@booster", "bot": false, "emojis": []
            },
            "reblog": {
                "id": "1104512345670001",
                "uri": "https://other.example/users/orig/statuses/1",
                "created_at": "2026-01-01T00:00:00.000Z",
                "content": "<p>The original text.</p>",
                "visibility": "public", "sensitive": false, "spoiler_text": "",
                "media_attachments": [], "reblog": null,
                "in_reply_to_id": null, "in_reply_to_account_id": null,
                "url": "https://other.example/@orig/1", "poll": null, "card": null,
                "emojis": [], "tags": [], "mentions": [],
                "replies_count": 4, "reblogs_count": 31, "favourites_count": 77,
                "edited_at": null, "language": "en",
                "account": {
                    "id": "3", "username": "orig", "acct": "orig@other.example",
                    "display_name": "Original Author",
                    "avatar": "https://files.example/o.png", "avatar_static": "https://files.example/o.png",
                    "url": "https://other.example/@orig", "bot": false, "emojis": []
                }
            }
        }]
        """
        let transport = StubTransport([.json(boost)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        // Ordered by when it was boosted, not when the original was written.
        #expect(item.publishedAt == (try Date("2026-09-03T12:00:00.000Z", strategy: .iso8601)))
        // But the content and author are the original's.
        #expect(item.title == "The original text.")
        #expect(item.authorName == "Original Author")
        #expect(item.urlString == "https://other.example/@orig/1")
        #expect(item.iconURLString == "https://files.example/o.png")
        // And so are the counts. A boost wrapper's own counts are always zero, so reading them
        // from the outer status would report every boosted post as having reached nobody.
        #expect(item.engagement == StatusEngagement(
            replyCount: 4,
            reblogCount: 31,
            favouriteCount: 77,
            boostedByName: "Booster"
        ))
    }

    @Test("A plain status carries its own counts and its parent")
    func engagementIsIngested() async throws {
        let status = """
        [{
            "id": "1104512345678001",
            "uri": "https://mastodon.social/users/a/statuses/1",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "<p>A reply of mine.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": "1104512345670000", "in_reply_to_account_id": "9",
            "url": "https://mastodon.social/@a/1", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 2, "reblogs_count": 5, "favourites_count": 9,
            "edited_at": null, "language": "en",
            "account": {
                "id": "1", "username": "a", "acct": "a", "display_name": "Ada",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            }
        }]
        """
        let transport = StubTransport([.json(status)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        #expect(item.engagement == StatusEngagement(
            replyCount: 2,
            reblogCount: 5,
            favouriteCount: 9,
            // Carried so the detail view knows there is a conversation before fetching one.
            inReplyToStatusID: "1104512345670000"
        ))
    }

    /// The list is exactly where the user has not opted in to seeing warned content. Showing the
    /// post's text next to its own content warning would defeat the warning entirely.
    @Test("A content warning replaces the post text in the list")
    func contentWarningReplacesListText() async throws {
        let warned = """
        [{
            "id": "1104512345678500",
            "uri": "https://mastodon.social/users/a/statuses/500",
            "created_at": "2026-09-03T10:00:00.000Z",
            "content": "<p>The spoiler itself, which must not leak into the list.</p>",
            "visibility": "public", "sensitive": true, "spoiler_text": "spoilers for the finale",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@a/500", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "edited_at": null, "language": "en",
            "account": {
                "id": "1", "username": "a", "acct": "a", "display_name": "Author A",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            }
        }]
        """
        let transport = StubTransport([.json(warned)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        #expect(item.title == "spoilers for the finale")
        // Neither the title nor the excerpt may carry the warned text.
        #expect(!item.title.contains("must not leak"))
        #expect(item.excerpt.isEmpty)
        // The real content is still stored, for the detail view to reveal on request.
        #expect(item.contentHTML.contains("must not leak"))
    }

    @Test("Attachments map, and ones still processing are dropped")
    func mapsAttachments() async throws {
        let withMedia = """
        [{
            "id": "1104512345678600",
            "uri": "u", "created_at": "2026-09-03T10:00:00.000Z",
            "content": "<p>x</p>", "visibility": "public", "sensitive": false, "spoiler_text": "",
            "reblog": null, "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@a/600", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "edited_at": null, "language": "en",
            "account": {
                "id": "1", "username": "a", "acct": "a", "display_name": "A",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            },
            "media_attachments": [
                { "id": "1", "type": "image", "url": "https://files.example/1.jpg",
                  "preview_url": "https://files.example/1-s.jpg", "remote_url": null,
                  "description": "Alt text", "blurhash": "abc",
                  "meta": { "original": { "width": 800, "height": 600, "aspect": 1.333 } } },
                { "id": "2", "type": "video", "url": "https://files.example/2.mp4",
                  "preview_url": null, "remote_url": null, "description": null,
                  "blurhash": null, "meta": null },
                { "id": "3", "type": "image", "url": null, "preview_url": null,
                  "remote_url": null, "description": null, "blurhash": null, "meta": null }
            ]
        }]
        """
        let transport = StubTransport([.json(withMedia)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let attachments = await sink.items.values.first!.attachments
        // The third is still being processed and has no URL, so it is dropped rather than stored as
        // a permanently broken tile.
        #expect(attachments.count == 2)
        #expect(attachments[0].kind == .image)
        #expect(attachments[0].describedAs == "Alt text")
        #expect(attachments[0].blurhash == "abc")
        #expect(attachments[0].width == 800)
        #expect(attachments[1].kind == .video)
    }

    @Test("The home timeline registers as a source")
    func registersHomeSource() async throws {
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        try await makePlanner(StubTransport([]), sink: sink).refreshSource()

        let sources = await sink.sources
        #expect(sources.count == 1)
        #expect(sources[0].id == SourceIdentifier.mastodonHome(accountID: accountID))
        #expect(sources[0].kind == .status)
        #expect(sources[0].title == "Home")
    }

    // MARK: - Link previews and Like state

    /// One status carrying everything the two new column groups come from.
    private func statusWithCardAndFlags(
        card: String,
        favourited: String = "true",
        reblogged: String = "false"
    ) -> String {
        """
        [{
            "id": "1104512345678009",
            "uri": "https://mastodon.social/users/a/statuses/9",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "<p>Look at this.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@a/9", "poll": null,
            "card": \(card),
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 1, "favourites_count": 2,
            "favourited": \(favourited), "reblogged": \(reblogged),
            "edited_at": null, "language": "en",
            "account": {
                "id": "1", "username": "a", "acct": "a", "display_name": "Ada",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            }
        }]
        """
    }

    /// The instance has already resolved the link's oEmbed or OpenGraph data, so ingest reads it
    /// off the timeline response rather than fetching the linked page itself.
    @Test("A post's link preview is ingested from the instance's own card")
    func linkCardIsIngested() async throws {
        let card = """
        {"url":"https://www.example.com/a-piece","title":"A headline","description":"A blurb.",
         "type":"link","image":"https://cdn.example.com/og.png","provider_name":"Example"}
        """
        let transport = StubTransport([.json(statusWithCardAndFlags(card: card))])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        #expect(item.linkCard == LinkCard(
            urlString: "https://www.example.com/a-piece",
            title: "A headline",
            summary: "A blurb.",
            imageURLString: "https://cdn.example.com/og.png"
        ))
    }

    /// Instances hand over cards with empty strings in them, for a link whose target answered with
    /// nothing usable. Storing one would put an empty box under the post.
    @Test("A card with no headline is ingested as no card")
    func emptyCardIsNotIngested() async throws {
        let card = """
        {"url":"https://www.example.com/x","title":"","description":"","type":"link","image":null}
        """
        let transport = StubTransport([.json(statusWithCardAndFlags(card: card))])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        #expect(await sink.items.values.first!.linkCard == nil)
    }

    @Test("A post with no link has no preview")
    func noCardMeansNoPreview() async throws {
        let transport = StubTransport([.json(statusWithCardAndFlags(card: "null"))])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        #expect(await sink.items.values.first!.linkCard == nil)
    }

    /// What turns Like into Unlike. Read from the same response, since Mastodon answers an
    /// authenticated timeline request with the asking account's own state on every post.
    @Test("The reader's own Like and Boost state is ingested")
    func interactionStateIsIngested() async throws {
        let transport = StubTransport([
            .json(statusWithCardAndFlags(card: "null", favourited: "true", reblogged: "false")),
        ])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let engagement = await sink.items.values.first!.engagement
        #expect(engagement?.isFavourited == true)
        #expect(engagement?.isReblogged == false)
    }

    /// A boost wrapper's own flags are about the act of boosting, and its card is always null. Both
    /// belong to the post.
    @Test("A boost reads its card and flags from the post it wraps")
    func boostReadsThroughToThePost() async throws {
        let card = """
        {"url":"https://www.example.com/a-piece","title":"A headline","description":"",
         "type":"link","image":null}
        """
        let inner = """
        {
            "id": "1104512345670001",
            "uri": "https://other.example/users/orig/statuses/1",
            "created_at": "2026-09-01T08:00:00.000Z",
            "content": "<p>The original.</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": "https://other.example/@orig/1", "poll": null,
            "card": \(card),
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 1, "reblogs_count": 2, "favourites_count": 3,
            "favourited": true, "reblogged": true,
            "edited_at": null, "language": "en",
            "account": {
                "id": "3", "username": "orig", "acct": "orig@other.example",
                "display_name": "Original Author",
                "avatar": "https://files.example/o.png", "avatar_static": null,
                "url": "https://other.example/@orig", "bot": false, "emojis": []
            }
        }
        """
        let wrapper = """
        [{
            "id": "1104512345678100",
            "uri": "https://mastodon.social/users/b/statuses/100/activity",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "", "visibility": "public", "sensitive": false, "spoiler_text": "",
            "media_attachments": [],
            "in_reply_to_id": null, "in_reply_to_account_id": null,
            "url": null, "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "favourited": false, "reblogged": false,
            "edited_at": null, "language": null,
            "account": {
                "id": "2", "username": "booster", "acct": "booster", "display_name": "Booster",
                "avatar": "https://files.example/b.png", "avatar_static": null,
                "url": "https://mastodon.social/@booster", "bot": false, "emojis": []
            },
            "reblog": \(inner)
        }]
        """

        let transport = StubTransport([.json(wrapper)])
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")

        _ = try await makePlanner(transport, sink: sink).ingest()

        let item = await sink.items.values.first!
        #expect(item.linkCard?.title == "A headline")
        #expect(item.engagement?.isFavourited == true)
        #expect(item.engagement?.isReblogged == true)
    }
}
