import Foundation
import ReadReadModel
import ReadReadSupport
import ReadReadTestSupport
import SwiftData
import Testing

@testable import ReadReadUI

/// The loader's whole job is *when*, not what. Splitting the decision from the request is what
/// keeps the comments off the network while the article is still arriving, and that split is
/// invisible from the outside — nothing about a rendered pane says whether two fetches raced.
@Suite("CommentsLoader")
@MainActor
struct CommentsLoaderTests {

    private let url = "https://example.com/2026/09/widgets/"

    private var wordPressPage: String {
        """
        <!doctype html><html><head>
        <link rel="alternate" type="application/json" href="https://example.com/wp-json/wp/v2/posts/482">
        </head><body class="postid-482"><article><p>The article.</p></article></body></html>
        """
    }

    private var commentJSON: String {
        """
        [{"id": 1, "parent": 0, "author_name": "Jo", "date_gmt": "2026-09-01T09:12:00",
          "content": {"rendered": "<p>A thought.</p>"}}]
        """
    }

    /// A store with one feed and one of its articles.
    private func fixture(loadsComments: Bool, kind: ItemKind = .article, hasURL: Bool = true) throws
        -> (ModelContext, CachedItem) {
        let context = ModelContext(try ReadReadStore.inMemoryContainer())
        let accountID = UUID()
        let sourceID = "freshrss:\(accountID):feed/1"

        context.insert(CachedSource(
            id: sourceID,
            accountID: accountID,
            kind: .article,
            title: "A Feed",
            loadsComments: loadsComments
        ))

        let item = CachedItem(
            id: "freshrss:\(accountID):abc",
            sourceID: sourceID,
            accountID: accountID,
            kind: kind,
            title: "Widgets",
            urlString: hasURL ? url : nil,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sortKey: SortKey(millis: 1_800_000_000_000, id: "abc"),
            ingestKey: SortKey(millis: 1_800_000_000_000, id: "abc")
        )
        context.insert(item)
        try context.save()
        return (context, item)
    }

    private func loader(_ transport: StubTransport) -> CommentsLoader {
        CommentsLoader(fetcher: CommentsFetcher(transport: transport))
    }

    /// Waits for the loader to settle, bounded so a hang fails rather than blocks.
    private func settled(_ loader: CommentsLoader) async -> CommentsLoader.State {
        for _ in 0..<400 {
            if loader.state != .loading { return loader.state }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the loader never settled")
        return loader.state
    }

    // MARK: - The split

    /// The point of the whole thing: deciding that an article has comments must cost nothing on
    /// the network, so the article's own fetch is never competing with one for its comments.
    @Test("Preparing decides without fetching anything")
    func prepareIssuesNoRequest() async throws {
        let transport = StubTransport([], fallback: .json("[]"))
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)

        #expect(loader.state == .pending)
        #expect(await transport.requestCount == 0)
    }

    @Test("Starting is what goes to the network")
    func startIssuesTheRequests() async throws {
        let transport = StubTransport([
            .statusWithHeaders(200, headers: ["Content-Type": "text/html"], body: wordPressPage),
            .json(commentJSON),
        ])
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()
        #expect(loader.state == .loading)

        let state = await settled(loader)
        guard case .loaded(.threads(let trees)) = state else {
            Issue.record("expected threads, got \(state)")
            return
        }
        #expect(trees.map(\.id) == [1])
        #expect(await transport.requestCount == 2)
    }

    /// The view calls this every time the web view finishes a navigation, which happens again for
    /// a reading-size change — so a second call must not start a second fetch.
    @Test("Starting twice fetches once")
    func startIsIdempotent() async throws {
        let transport = StubTransport([
            .statusWithHeaders(200, headers: ["Content-Type": "text/html"], body: wordPressPage),
            .json(commentJSON),
        ])
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()
        loader.start()
        _ = await settled(loader)

        #expect(await transport.requestCount == 2)
    }

    /// Selecting another article before the first one's document is up. Without clearing what
    /// `prepare` queued, the next `start` would fetch the comments of an article nobody is on.
    @Test("Resetting cancels a fetch that never started")
    func resetDropsThePendingFetch() async throws {
        let transport = StubTransport([], fallback: .json("[]"))
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.reset()
        loader.start()

        #expect(loader.state == .notRequested)
        #expect(await transport.requestCount == 0)
    }

    // MARK: - Deciding not to

    @Test("A feed with comments off asks for nothing")
    func honoursTheFeedSetting() async throws {
        let transport = StubTransport([], fallback: .json("[]"))
        let (context, item) = try fixture(loadsComments: false)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()

        #expect(loader.state == .notRequested)
        #expect(await transport.requestCount == 0)
    }

    /// A post is its own content — there is no page to go and find a discussion on.
    @Test("A Mastodon post has no comments to load")
    func skipsStatuses() throws {
        let transport = StubTransport([], fallback: .json("[]"))
        let (context, item) = try fixture(loadsComments: true, kind: .status)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        #expect(loader.state == .notRequested)
    }

    @Test("An item with no link has no comments to load")
    func skipsItemsWithoutALink() throws {
        let transport = StubTransport([], fallback: .json("[]"))
        let (context, item) = try fixture(loadsComments: true, hasURL: false)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        #expect(loader.state == .notRequested)
    }

    /// Arrowing back to an article whose page was already found to have no comments must not put a
    /// spinner up, nor fetch that page again.
    @Test("A page already known to have none is answered without a request")
    func remembersPagesWithoutComments() async throws {
        let bare = "<html><head></head><body><p>Hand written.</p></body></html>"
        let transport = StubTransport(
            [.statusWithHeaders(200, headers: ["Content-Type": "text/html"], body: bare)],
            fallback: .status(500)
        )
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()
        #expect(await settled(loader) == .loaded(.unsupported))
        #expect(await transport.requestCount == 1)

        // Selected again: answered synchronously, and nothing goes out.
        loader.prepare(item, in: context)
        #expect(loader.state == .loaded(.unsupported))
        loader.start()
        #expect(await transport.requestCount == 1)
    }

    /// The saving the discovery cache exists for. The comments themselves are never reused — a
    /// discussion gains replies while the article above it is being read.
    @Test("Re-opening an article re-reads the comments but not the page")
    func reusesDiscovery() async throws {
        let transport = StubTransport([
            .statusWithHeaders(200, headers: ["Content-Type": "text/html"], body: wordPressPage),
            .json(commentJSON),
            .json(commentJSON),
        ])
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()
        _ = await settled(loader)
        #expect(await transport.requestCount == 2)

        loader.prepare(item, in: context)
        loader.start()
        _ = await settled(loader)

        // Three, not four: the page was not fetched a second time.
        #expect(await transport.requestCount == 3)
        #expect(await transport.urls[2].contains("wp/v2/comments"))
    }

    // MARK: - Failing

    /// The message must never carry the error's own description: an `HTTPError` holds a prefix of
    /// the response body, which for a page behind a bot wall is whatever that site chose to put
    /// in it.
    @Test("A failure is reported in the app's own words")
    func describesFailuresSafely() async throws {
        let transport = StubTransport(
            [.statusWithHeaders(200, headers: ["Content-Type": "application/pdf"], body: "%PDF")]
        )
        let (context, item) = try fixture(loadsComments: true)
        let loader = loader(transport)

        loader.prepare(item, in: context)
        loader.start()

        guard case .failed(let message) = await settled(loader) else {
            Issue.record("expected a failure, got \(loader.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!message.contains("PDF"))
    }
}
