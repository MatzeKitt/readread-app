import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import MastodonAPI

/// Replies arrive with the post they answer.
///
/// Looked up during ingest so a row never grows a parent while somebody is reading past it, and
/// caught up afterwards by the backfill for the replies ingest could not answer. What matters most
/// is the line between *no parent* and *did not find out*: the first is recorded so nothing asks
/// again, and the second must not be, or one bad connection would hide a parent for good.
@Suite("Reply parents")
struct ReplyParentTests {

    private let accountID = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!

    private func makeClient(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(
            instanceURL: URL(string: "https://mastodon.social")!,
            accessToken: "tok",
            http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
        )
    }

    /// One status, whole, because `MastodonStatus` decodes strictly.
    private func statusJSON(
        id: String,
        content: String,
        inReplyTo: String? = nil,
        spoiler: String = "",
        author: String = "Ada",
        quote: String = "null",
        origin: String = "mastodon.social",
        originID: String? = nil
    ) -> String {
        """
        {
            "id": "\(id)",
            "uri": "https://\(origin)/users/a/statuses/\(originID ?? id)",
            "created_at": "2026-09-03T12:00:00.000Z",
            "content": "<p>\(content)</p>",
            "visibility": "public", "sensitive": false, "spoiler_text": "\(spoiler)",
            "media_attachments": [], "reblog": null,
            "in_reply_to_id": \(inReplyTo.map { "\"\($0)\"" } ?? "null"), "in_reply_to_account_id": null,
            "url": "https://mastodon.social/@a/\(id)", "poll": null, "card": null,
            "emojis": [], "tags": [], "mentions": [],
            "replies_count": 0, "reblogs_count": 0, "favourites_count": 0,
            "edited_at": null, "language": "en", "quote": \(quote),
            "account": {
                "id": "1", "username": "a", "acct": "a@mastodon.social", "display_name": "\(author)",
                "avatar": "https://files.example/a.png", "avatar_static": null,
                "url": "https://mastodon.social/@a", "bot": false, "emojis": []
            }
        }
        """
    }

    private func ingest(_ transport: StubTransport) async throws -> RecordingIngestSink {
        let sink = RecordingIngestSink(accountID: accountID, streamKey: "home")
        let planner = MastodonIngestPlanner(client: makeClient(transport), sink: sink, accountID: accountID)
        _ = try await planner.ingest()
        return sink
    }

    /// The `created_at` every status in ``statusJSON`` carries.
    private let publishedAt = ISO8601DateFormatter().date(from: "2026-09-03T12:00:00Z")!

    private func parent(of statusID: String, in sink: RecordingIngestSink) async -> ReplyParentLookup? {
        await sink.items[SourceIdentifier.mastodonItem(accountID: accountID, statusID: statusID)]?.replyParent
    }

    // MARK: - Client

    @Test("One status is fetched from its own path")
    func fetchesOneStatus() async throws {
        let transport = StubTransport([.json(statusJSON(id: "77", content: "Hello"))])

        let status = try await makeClient(transport).status(MastodonStatusID("77"))

        #expect(status?.id.rawValue == "77")
        #expect(await transport.urls == ["https://mastodon.social/api/v1/statuses/77"])
    }

    /// A 404 is how an instance says a post is gone or hidden from this account, which is an
    /// answer about the post rather than a failure.
    @Test("A missing status is nil, not an error")
    func missingStatusIsNil() async throws {
        let transport = StubTransport([.status(404, body: #"{"error":"Record not found"}"#)])

        let status = try await makeClient(transport).status(MastodonStatusID("77"))

        #expect(status == nil)
    }

    // MARK: - Ingest

    /// A thread posted in parts arrives as replies to each other on one page, and asking the
    /// instance for posts already in hand would be a request per part for nothing.
    @Test("A parent on the same page costs no request")
    func parentOnThePage() async throws {
        let page = """
        [\(statusJSON(id: "2", content: "Part two", inReplyTo: "1")),
         \(statusJSON(id: "1", content: "Part one"))]
        """
        let transport = StubTransport([.json(page)])

        let sink = try await ingest(transport)

        guard case .found(let parent, let payload) = await parent(of: "2", in: sink) else {
            Issue.record("The reply was written without its parent")
            return
        }
        #expect(parent.authorName == "Ada")
        #expect(parent.authorHandle == "a@mastodon.social")
        #expect(parent.text == "Part one")
        #expect(payload != nil)
        // The post that replies to nothing is not looked up at all.
        #expect(await self.parent(of: "1", in: sink) == nil)
        #expect(await transport.requestCount == 1)
    }

    @Test("A parent elsewhere is fetched before the reply is written")
    func parentFromTheInstance() async throws {
        let transport = StubTransport([
            .json("[\(statusJSON(id: "9", content: "Agreed", inReplyTo: "5"))]"),
            .json(statusJSON(id: "5", content: "Tabs are better", author: "Grace")),
        ])

        let sink = try await ingest(transport)

        guard case .found(let parent, _) = await parent(of: "9", in: sink) else {
            Issue.record("The reply was written without its parent")
            return
        }
        #expect(parent.authorName == "Grace")
        #expect(parent.text == "Tabs are better")
        #expect(await transport.urls.last == "https://mastodon.social/api/v1/statuses/5")
    }

    /// The row shows a warned parent's text, and prints its warning underneath.
    @Test("A warned parent keeps its text, with the warning beside it")
    func warnedParent() async throws {
        let page = """
        [\(statusJSON(id: "2", content: "Reply", inReplyTo: "1")),
         \(statusJSON(id: "1", content: "The spoiler itself", spoiler: "Film ending"))]
        """

        let sink = try await ingest(StubTransport([.json(page)]))

        guard case .found(let parent, _) = await parent(of: "2", in: sink) else {
            Issue.record("The reply was written without its parent")
            return
        }
        #expect(parent.contentWarning == "Film ending")
        #expect(parent.text == "The spoiler itself")
    }

    @Test("A deleted parent is recorded as gone")
    func deletedParent() async throws {
        let transport = StubTransport([
            .json("[\(statusJSON(id: "9", content: "Agreed", inReplyTo: "5"))]"),
            .status(404),
        ])

        let sink = try await ingest(transport)

        #expect(await parent(of: "9", in: sink) == .unavailable)
    }

    /// Recording "gone" here would keep the backfill from ever asking again, and the parent would
    /// stay missing long after the connection came back.
    @Test("A parent that could not be fetched is left for later, and the reply still lands")
    func failedParentIsNotRecorded() async throws {
        let transport = StubTransport([
            .json("[\(statusJSON(id: "9", content: "Agreed", inReplyTo: "5"))]"),
            .failure(.notConnectedToInternet),
        ])

        let sink = try await ingest(transport)

        #expect(await sink.items[SourceIdentifier.mastodonItem(accountID: accountID, statusID: "9")] != nil)
        #expect(await parent(of: "9", in: sink) == nil)
    }

    // MARK: - Backfill

    private func storedRow(id statusID: String, json: String, inReplyTo: String?) -> CachedItem {
        let id = SourceIdentifier.mastodonItem(accountID: accountID, statusID: statusID)
        return CachedItem(
            id: id,
            sourceID: SourceIdentifier.mastodonHome(accountID: accountID),
            accountID: accountID,
            kind: .status,
            title: "A post.",
            excerpt: "A post.",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000 + (Int64(statusID) ?? 0), id: id),
            ingestKey: SortKey(millis: 1_700_000_000_000, id: id),
            inReplyToStatusID: inReplyTo,
            mastodonPayload: Data(json.utf8)
        )
    }

    private func stored(_ statusID: String, in container: ModelContainer) throws -> CachedItem? {
        let id = SourceIdentifier.mastodonItem(accountID: accountID, statusID: statusID)
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetch(descriptor).first
    }

    private func store(_ rows: [CachedItem]) throws -> ModelContainer {
        let container = try ReadReadStore.inMemoryContainer()
        let context = ModelContext(container)
        for row in rows { context.insert(row) }
        try context.save()
        return container
    }

    /// The walk never revisits a post it already has, so a reply stored before parents were looked
    /// up would otherwise stay without one for good.
    @Test("A stored reply gains its parent from the instance")
    func backfillFetches() async throws {
        let container = try store([
            storedRow(id: "9", json: statusJSON(id: "9", content: "Agreed", inReplyTo: "5"), inReplyTo: "5"),
        ])
        let transport = StubTransport([.json(statusJSON(id: "5", content: "Tabs are better", author: "Grace"))])

        let answered = try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport))

        #expect(answered == 1)
        let row = try stored("9", in: container)
        #expect(row?.replyParent?.authorName == "Grace")
        #expect(row?.replyParentPayload != nil)
    }

    /// A warned parent used to be recorded as its warning alone. Its payload holds the whole post,
    /// so the row is rebuilt without asking the instance again.
    @Test("A warned parent recorded as its warning is rebuilt from its payload")
    func backfillRebuildsWarnedParent() async throws {
        let parentJSON = statusJSON(id: "5", content: "The ending", spoiler: "Film ending", author: "Grace")
        let row = storedRow(id: "9", json: statusJSON(id: "9", content: "Agreed", inReplyTo: "5"), inReplyTo: "5")
        row.replyParentAuthorName = "Grace"
        row.replyParentText = "Film ending"
        row.replyParentHasContentWarning = true
        row.replyParentPayload = Data(parentJSON.utf8)

        // Until then the row draws the warning alone, not the warning as if it were the post.
        #expect(row.replyParent?.text == "")
        #expect(row.replyParent?.contentWarning == "Film ending")

        let container = try store([row])
        let transport = StubTransport()

        try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport))

        let parent = try stored("9", in: container)?.replyParent
        #expect(parent?.text == "The ending")
        #expect(parent?.contentWarning == "Film ending")
        #expect(await transport.requestCount == 0)
    }

    @Test("A parent already in the store costs no request")
    func backfillUsesTheStore() async throws {
        let container = try store([
            storedRow(id: "5", json: statusJSON(id: "5", content: "Tabs are better", author: "Grace"), inReplyTo: nil),
            storedRow(id: "9", json: statusJSON(id: "9", content: "Agreed", inReplyTo: "5"), inReplyTo: "5"),
        ])
        let transport = StubTransport()

        try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport))

        #expect(try stored("9", in: container)?.replyParent?.text == "Tabs are better")
        #expect(await transport.requestCount == 0)
    }

    /// The sentinel is what takes the row out of the backfill's search. Without it a deleted
    /// parent would be asked for again after every refresh, for as long as the reply is kept.
    @Test("A deleted parent is asked for once")
    func backfillRecordsGone() async throws {
        let container = try store([
            storedRow(id: "9", json: statusJSON(id: "9", content: "Agreed", inReplyTo: "5"), inReplyTo: "5"),
        ])
        let transport = StubTransport([.status(404)])
        let backfill = ReplyParentBackfill(modelContainer: container)

        try await backfill.fill(accountID: accountID, client: makeClient(transport))
        let second = try await backfill.fill(accountID: accountID, client: makeClient(transport))

        #expect(second == 0)
        #expect(await transport.requestCount == 1)
        #expect(try stored("9", in: container)?.replyParentAuthorName == "")
        #expect(try stored("9", in: container)?.replyParent == nil)
    }

    // MARK: - Quotes

    /// The paragraph Mastodon writes into a quote post for apps that cannot show quotes, verbatim
    /// from a real one.
    private let quoteFallback = #"<p class="quote-inline">RE: <a href="https://front-end.social/@matuzo/117284932263089457" target="_blank" rel="nofollow noopener" translate="no"><span class="invisible">https://</span><span class="ellipsis">front-end.social/@matuzo/11728</span><span class="invisible">4932263089457</span></a></p>"#

    private func acceptedQuote(of json: String) -> String {
        #"{"state": "accepted", "quoted_status": "# + json + "}"
    }

    /// The case that was reported: a quote post showed only its "RE: <link>" line, because the
    /// quoted post arrives in a field the status type did not read.
    @Test("A quote post is written with the quoted post, at no cost")
    func quotedPost() async throws {
        let quoted = statusJSON(id: "117284932263089457", content: "Submit to HTMHell", author: "Manuel")
        let quoting = statusJSON(
            id: "117372565388294036",
            content: "It is your last chance",
            quote: acceptedQuote(of: quoted)
        )
        let transport = StubTransport([.json("[\(quoting)]")])

        let sink = try await ingest(transport)

        guard case .found(let parent, let payload) = await parent(of: "117372565388294036", in: sink) else {
            Issue.record("The quote post was written without what it quotes")
            return
        }
        #expect(parent.isQuote)
        #expect(parent.authorName == "Manuel")
        #expect(parent.text == "Submit to HTMHell")
        #expect(payload != nil)
        #expect(await transport.requestCount == 1)
    }

    /// The row has room for one post above it, and the quote is part of what the post says.
    @Test("A post that quotes and replies shows the quote, without fetching the parent")
    func quoteWinsOverParent() async throws {
        let quoting = statusJSON(
            id: "9",
            content: "This, again",
            inReplyTo: "5",
            quote: acceptedQuote(of: statusJSON(id: "3", content: "The quoted one", author: "Manuel"))
        )
        let transport = StubTransport([.json("[\(quoting)]")])

        let sink = try await ingest(transport)

        guard case .found(let parent, _) = await parent(of: "9", in: sink) else {
            Issue.record("The post was written without what it quotes")
            return
        }
        #expect(parent.isQuote)
        #expect(parent.authorName == "Manuel")
        #expect(await transport.requestCount == 1)
    }

    /// A quote whose author has not allowed it, or has taken it back, comes without the quoted
    /// post. The answer is recorded, so the backfill's search for quote posts lets it go.
    @Test("A quote that may not be shown is an answer, not a gap")
    func unshownQuote() async throws {
        let quoting = statusJSON(id: "9", content: "Look", quote: #"{"state": "revoked", "quoted_status": null}"#)

        let sink = try await ingest(StubTransport([.json("[\(quoting)]")]))

        #expect(await parent(of: "9", in: sink) == .unavailable)
    }

    @Test("The fallback line goes, and the rest of the post stays")
    func fallbackIsRemoved() {
        let html = quoteFallback + "<p>It&#39;s your last chance.</p>"

        #expect(QuoteFallback.removing(from: html) == "<p>It&#39;s your last chance.</p>")
        #expect(QuoteFallback.removing(from: "<p>No quote here.</p>") == "<p>No quote here.</p>")
    }

    /// Quote posts already in the store lost the quote when they were encoded, so the post itself
    /// has to be fetched again — and is found by its fallback paragraph.
    @Test("A stored quote post gains its quoted post by being fetched again")
    func backfillFetchesQuotes() async throws {
        let stored = statusJSON(id: "9", content: "It is your last chance")
        var row = storedRow(id: "9", json: stored, inReplyTo: nil)
        row.contentHTML = quoteFallback + "<p>It is your last chance</p>"
        let container = try store([row])
        let refetched = statusJSON(
            id: "9",
            content: "It is your last chance",
            quote: acceptedQuote(of: statusJSON(id: "3", content: "Submit to HTMHell", author: "Manuel"))
        )
        let transport = StubTransport([.json(refetched)])

        try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport))

        let filled = try self.stored("9", in: container)
        #expect(filled?.replyParent?.authorName == "Manuel")
        #expect(filled?.replyParentIsQuote == true)
        #expect(await transport.urls == ["https://mastodon.social/api/v1/statuses/9"])
    }

    // MARK: - Pending quotes

    private let pendingQuote = #"{"state": "pending", "quoted_status": null}"#

    /// A client for the quoting post's own server, on the same script as the reader's instance so
    /// a test reads as the order the requests go out in.
    private func originClient(_ transport: StubTransport) -> @Sendable (URL) -> MastodonClient {
        { url in
            MastodonClient(
                instanceURL: url,
                accessToken: nil,
                http: HTTPClient(transport: transport, policy: RetryPolicy(maxAttempts: 1), clock: TestClock())
            )
        }
    }

    /// A stored quote post, as the reported one was: fetched while its quote was pending.
    private func storedPendingQuote() throws -> ModelContainer {
        var row = storedRow(id: "9", json: statusJSON(id: "9", content: "Look"), inReplyTo: nil)
        row.contentHTML = quoteFallback + "<p>Look</p>"
        return try store([row])
    }

    /// A quoting post on mas.to, as the reader's instance holds it: under its own id, `9`, and
    /// with the quote still pending.
    private var pendingOnInstance: String {
        statusJSON(id: "9", content: "Look", quote: pendingQuote, origin: "mas.to", originID: "117453084523853007")
    }

    @Test("A quote still waiting for approval is left for the backfill")
    func pendingQuoteIsNotRecorded() async throws {
        let sink = try await ingest(StubTransport([.json("[\(pendingOnInstance)]")]))

        #expect(await sink.items[SourceIdentifier.mastodonItem(accountID: accountID, statusID: "9")] != nil)
        #expect(await parent(of: "9", in: sink) == nil)
    }

    /// The case that was reported second: the reader's instance kept the quote pending for days,
    /// while mas.to, where the quoting post lives, had it approved. The quoted post is resolved on
    /// the reader's instance, so its ids are ones this account can act on.
    @Test("A quote pending here and approved at its origin is shown, resolved on this instance")
    func approvedAtOrigin() async throws {
        let container = try storedPendingQuote()
        let atOrigin = statusJSON(
            id: "117453084523853007",
            content: "Look",
            quote: acceptedQuote(of: statusJSON(id: "117452679557772844", content: "Flock", author: "Benjamin")),
            origin: "mas.to"
        )
        let resolved = statusJSON(id: "4242", content: "Flock", author: "Benjamin")
        let transport = StubTransport([
            .json(pendingOnInstance),
            .json(atOrigin),
            .json(#"{"statuses": [\#(resolved)], "accounts": []}"#),
        ])

        let answered = try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport), originClient: originClient(transport))

        #expect(answered == 1)
        let row = try stored("9", in: container)
        #expect(row?.replyParent?.authorName == "Benjamin")
        #expect(row?.replyParentIsQuote == true)
        let payload = try #require(row?.replyParentPayload)
        #expect(try JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload).id.rawValue == "4242")

        let urls = await transport.urls
        #expect(urls.count == 3)
        #expect(urls.dropFirst().first == "https://mas.to/api/v1/statuses/117453084523853007")
        #expect(urls.last?.hasPrefix("https://mastodon.social/api/v2/search") == true)
        // Anonymous: the reader's token is for their own instance and goes nowhere else.
        let requests = await transport.requests
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A quote refused at its origin is an answer")
    func refusedAtOrigin() async throws {
        let container = try storedPendingQuote()
        let atOrigin = statusJSON(
            id: "117453084523853007",
            content: "Look",
            quote: #"{"state": "revoked", "quoted_status": null}"#,
            origin: "mas.to"
        )
        let transport = StubTransport([.json(pendingOnInstance), .json(atOrigin)])

        try await ReplyParentBackfill(modelContainer: container)
            .fill(accountID: accountID, client: makeClient(transport), originClient: originClient(transport))

        #expect(try stored("9", in: container)?.replyParentAuthorName == "")
        #expect(await transport.requestCount == 2)
    }

    @Test("A quote pending everywhere is asked about again, then approved")
    func pendingEverywhereThenApproved() async throws {
        let container = try storedPendingQuote()
        let pendingAtOrigin = statusJSON(
            id: "117453084523853007", content: "Look", quote: pendingQuote, origin: "mas.to"
        )
        let approvedHere = statusJSON(
            id: "9",
            content: "Look",
            quote: acceptedQuote(of: statusJSON(id: "3", content: "Submit to HTMHell", author: "Manuel"))
        )
        let transport = StubTransport([.json(pendingOnInstance), .json(pendingAtOrigin), .json(approvedHere)])
        let backfill = ReplyParentBackfill(modelContainer: container)
        let now = publishedAt.addingTimeInterval(60)

        let first = try await backfill.fill(
            accountID: accountID, client: makeClient(transport), now: now, originClient: originClient(transport)
        )
        #expect(first == 0)
        #expect(try stored("9", in: container)?.replyParentAuthorName == nil)

        try await backfill.fill(
            accountID: accountID, client: makeClient(transport), now: now, originClient: originClient(transport)
        )
        #expect(try stored("9", in: container)?.replyParent?.authorName == "Manuel")
        #expect(await transport.requestCount == 3)
    }

    /// A quote nobody ever decides would otherwise be asked about after every refresh.
    @Test("A quote still undecided after a day is an answer")
    func undecidedAfterADay() async throws {
        let container = try storedPendingQuote()
        let transport = StubTransport([.json(pendingOnInstance), .status(401)])

        try await ReplyParentBackfill(modelContainer: container).fill(
            accountID: accountID,
            client: makeClient(transport),
            now: publishedAt.addingTimeInterval(2 * 24 * 60 * 60),
            originClient: originClient(transport)
        )

        #expect(try stored("9", in: container)?.replyParentAuthorName == "")
    }

    @Test("A post's own server is read off its ActivityPub address")
    func originOfAPost() throws {
        let decode = { (json: String) in try JSONDecoder.mastodon.decode(MastodonStatus.self, from: Data(json.utf8)) }

        let origin = try #require(ReplyParentResolver.origin(of: decode(pendingOnInstance)))
        #expect(origin.instanceURL.absoluteString == "https://mas.to")
        #expect(origin.id.rawValue == "117453084523853007")

        let otherShape = statusJSON(id: "9", content: "Look").replacingOccurrences(
            of: "/users/a/statuses/9", with: "/notes/9xk2"
        )
        #expect(ReplyParentResolver.origin(of: try decode(otherShape)) == nil)
    }

    /// Rows recorded before pending quotes were asked about again: the reported post among them.
    @Test("Quote posts recorded as having nothing to show are reopened, once")
    func unshownQuotesAreReopened() throws {
        var quotePost = storedRow(id: "9", json: statusJSON(id: "9", content: "Look"), inReplyTo: nil)
        quotePost.contentHTML = quoteFallback + "<p>Look</p>"
        quotePost.record(.unavailable)
        // A reply whose parent was deleted, which no quote has anything to do with.
        let reply = storedRow(id: "8", json: statusJSON(id: "8", content: "Agreed", inReplyTo: "5"), inReplyTo: "5")
        reply.record(.unavailable)
        let container = try store([quotePost, reply])
        let defaults = try #require(UserDefaults(suiteName: "readread.quotes.\(UUID().uuidString)"))

        let reopened = try ReplyParentBackfill.reopenUnshownQuotesIfNeeded(
            in: ModelContext(container),
            defaults: defaults
        )

        #expect(reopened == 1)
        #expect(try stored("9", in: container)?.replyParentAuthorName == nil)
        #expect(try stored("8", in: container)?.replyParentAuthorName == "")

        // Recorded again by the backfill, and not reopened a second time.
        let row = try #require(try stored("9", in: container))
        row.record(.unavailable)
        try row.modelContext?.save()
        let again = try ReplyParentBackfill.reopenUnshownQuotesIfNeeded(
            in: ModelContext(container),
            defaults: defaults
        )
        #expect(again == 0)
        #expect(try stored("9", in: container)?.replyParentAuthorName == "")
    }
}
