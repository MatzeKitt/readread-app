import Foundation
import ReadReadSupport
import ReadReadTestSupport
import Testing

@testable import ReadReadModel

/// Two requests, a fallback between them and a wire format with three fields that are not the shape
/// they look like. The interesting failures here are all about what happens when a site answers
/// *partly* — which is what a stubbed transport can reproduce and a live one cannot.
@Suite("CommentsFetcher")
struct CommentsFetcherTests {

    private let url = URL(string: "https://example.com/2026/09/widgets/")!

    private func html(_ body: String) -> StubTransport.Response {
        .statusWithHeaders(200, headers: ["Content-Type": "text/html; charset=utf-8"], body: body)
    }

    /// A WordPress page as core renders its head, with a discussion in the body for the fallback
    /// to find.
    private var wordPressPage: String {
        """
        <!doctype html><html><head>
        <link rel="alternate" type="application/json" href="https://example.com/wp-json/wp/v2/posts/482">
        </head><body class="postid-482">
        <article><p>The article.</p></article>
        <div id="comments"><ol class="comment-list">
        <li><article class="comment-body"><p>As rendered by the theme.</p></article></li>
        </ol></div>
        </body></html>
        """
    }

    private func commentJSON(
        id: Int,
        parent: Int = 0,
        author: String = "Jo",
        date: String = "2026-09-01T09:12:00",
        avatar: String = #"{"48": "https://secure.gravatar.com/avatar/x?s=48", "96": "https://secure.gravatar.com/avatar/x?s=96"}"#
    ) -> String {
        """
        {"id": \(id), "parent": \(parent), "author_name": "\(author)", "author_url": "",
         "author_avatar_urls": \(avatar), "date_gmt": "\(date)",
         "content": {"rendered": "<p>Comment \(id)</p>"}}
        """
    }

    private func json(_ body: String, headers: [String: String] = [:]) -> StubTransport.Response {
        .statusWithHeaders(
            200,
            headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first },
            body: body
        )
    }

    // MARK: - The whole path

    @Test("A WordPress article yields its comments as threads")
    func fetchesThreads() async throws {
        let transport = StubTransport([
            html(wordPressPage),
            json("[\(commentJSON(id: 1)), \(commentJSON(id: 2, parent: 1, date: "2026-09-01T10:00:00"))]"),
        ])

        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome else {
            Issue.record("expected threads, got \(outcome)")
            return
        }
        #expect(trees.map(\.id) == [1])
        #expect(trees[0].replies.map(\.id) == [2])
        #expect(trees[0].comment.authorName == "Jo")
        // The largest offered, because these are drawn at a fixed size and the small one is soft.
        #expect(trees[0].comment.avatarURLString?.contains("s=96") == true)
        // An empty `author_url` is no address, not an address that is the empty string.
        #expect(trees[0].comment.authorURLString == nil)
    }

    /// `date_gmt` is ISO 8601 with the zone in the *field name* rather than in the value. Read as
    /// local time it does not fail, it shifts — silently, by the reader's own offset.
    @Test("A zone-less date_gmt is read as UTC")
    func readsDatesAsUTC() async throws {
        let transport = StubTransport([html(wordPressPage), json("[\(commentJSON(id: 1))]")])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome, let first = trees.first else {
            Issue.record("expected one thread, got \(outcome)")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: first.comment.publishedAt)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 1)
        #expect(parts.hour == 9)
        #expect(parts.minute == 12)
    }

    /// The body is a stranger's markup on somebody else's site — the least trustworthy HTML the
    /// reader renders — and it is sanitised where it is decoded rather than where it is drawn.
    @Test("A comment body arrives sanitised")
    func sanitisesBodies() async throws {
        let hostile = """
            [{"id": 1, "parent": 0, "author_name": "Spam", "date_gmt": "2026-09-01T09:00:00",
              "content": {"rendered": "<p onclick=\\"steal()\\">Hi<script>steal()</script></p><a href=\\"javascript:steal()\\">tap</a>"}}]
            """
        let transport = StubTransport([html(wordPressPage), json(hostile)])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome, let body = trees.first?.comment.contentHTML else {
            Issue.record("expected one thread, got \(outcome)")
            return
        }
        #expect(body.contains("Hi"))
        #expect(!body.contains("steal"))
        #expect(!body.lowercased().contains("onclick"))
        #expect(!body.lowercased().contains("javascript:"))
    }

    /// Avatars off site-wide makes this field `false`, not an object. A strict decode throws there
    /// and loses the whole page of comments over a picture.
    @Test("Avatars turned off site-wide cost the avatar, not the comment")
    func toleratesMissingAvatars() async throws {
        let transport = StubTransport([
            html(wordPressPage),
            json("[\(commentJSON(id: 1, avatar: "false"))]"),
        ])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome, let first = trees.first else {
            Issue.record("expected one thread, got \(outcome)")
            return
        }
        #expect(first.comment.avatarURLString == nil)
        #expect(first.comment.authorName == "Jo")
    }

    @Test("One malformed comment costs that comment, not the page")
    func skipsUnusableComments() async throws {
        let mixed = """
            [{"id": 1, "parent": 0, "author_name": "Jo", "date_gmt": "not a date",
              "content": {"rendered": "<p>Lost</p>"}},
             \(commentJSON(id: 2))]
            """
        let transport = StubTransport([html(wordPressPage), json(mixed)])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome else {
            Issue.record("expected threads, got \(outcome)")
            return
        }
        #expect(trees.map(\.id) == [2])
    }

    @Test("An anonymous comment still has a name to show")
    func namesAnonymousComments() async throws {
        let anonymous = """
            [{"id": 1, "parent": 0, "author_name": "  ", "date_gmt": "2026-09-01T09:00:00",
              "content": {"rendered": "<p>Hi</p>"}}]
            """
        let transport = StubTransport([html(wordPressPage), json(anonymous)])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome else {
            Issue.record("expected threads, got \(outcome)")
            return
        }
        #expect(trees.first?.comment.authorName.isEmpty == false)
    }

    // MARK: - Paging

    @Test("Comments are paged until the server says there are no more pages")
    func pagesUntilExhausted() async throws {
        let transport = StubTransport([
            html(wordPressPage),
            json("[\(commentJSON(id: 1))]", headers: ["X-WP-TotalPages": "2"]),
            json("[\(commentJSON(id: 2, date: "2026-09-02T09:00:00"))]", headers: ["X-WP-TotalPages": "2"]),
        ])

        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .threads(let trees) = outcome else {
            Issue.record("expected threads, got \(outcome)")
            return
        }
        #expect(trees.map(\.id) == [1, 2])
        #expect(await transport.requestCount == 3)
        #expect(await transport.queryItems(at: 2)["page"] == "2")
    }

    /// An absent header is one page. A site behind a proxy that strips it looks identical, and one
    /// page is the reading that does not walk off the end into a 400.
    @Test("No page-count header means one page")
    func stopsWithoutPageHeader() async throws {
        let transport = StubTransport([html(wordPressPage), json("[\(commentJSON(id: 1))]")])
        _ = try await CommentsFetcher(transport: transport).fetch(url)
        #expect(await transport.requestCount == 2)
    }

    /// A popular post's discussion is unbounded and a reading pane is not.
    @Test("Paging stops at the cap however many pages the server claims")
    func capsPages() async throws {
        let transport = StubTransport(
            [html(wordPressPage)],
            fallback: json("[\(commentJSON(id: 1))]", headers: ["X-WP-TotalPages": "9000"])
        )

        _ = try await CommentsFetcher(transport: transport).fetch(url)
        #expect(await transport.requestCount == CommentsFetcher.maximumPages + 1)
    }

    // MARK: - Falling back

    /// A site can advertise the API and then refuse to serve comments through it — switched off by
    /// a plugin, filtered to logged-in readers. The page already fetched still has the discussion.
    @Test("An endpoint that refuses falls back to the page's own comments")
    func fallsBackOnRefusedEndpoint() async throws {
        let transport = StubTransport([
            html(wordPressPage),
            .status(401, body: "{\"code\":\"rest_forbidden\"}"),
        ])

        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .markup(let markup) = outcome else {
            Issue.record("expected the page's markup, got \(outcome)")
            return
        }
        #expect(markup.contains("As rendered by the theme."))
    }

    /// An endpoint answering with an empty list while the page plainly shows comments is not a post
    /// with no discussion — it is an endpoint that will not talk about it.
    @Test("An empty API answer defers to comments visible on the page")
    func prefersMarkupOverEmptyAPI() async throws {
        let transport = StubTransport([html(wordPressPage), json("[]")])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .markup = outcome else {
            Issue.record("expected the page's markup, got \(outcome)")
            return
        }
    }

    /// With nothing on the page to defer to, an empty list means what it says.
    @Test("An empty API answer on a page with no comment section means no comments")
    func reportsNoComments() async throws {
        let bare = """
            <!doctype html><html><head>
            <link rel="alternate" type="application/json" href="https://example.com/wp-json/wp/v2/posts/482">
            </head><body><article><p>The article.</p></article></body></html>
            """
        let transport = StubTransport([html(bare), json("[]")])
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        #expect(outcome == .threads([]))
    }

    @Test("A page that is not WordPress reports no comments to load")
    func reportsUnsupported() async throws {
        let transport = StubTransport(html("<html><head></head><body><p>Hand written.</p></body></html>"))
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        #expect(outcome == .unsupported)
        // The page, and nothing after it: there is nowhere to ask.
        #expect(await transport.requestCount == 1)
    }

    /// A theme with comments but no reachable REST API — an old install, or a plugin that removed
    /// the discovery links.
    @Test("A page with comments but no API still shows them")
    func fallsBackWithoutAPI() async throws {
        let noAPI = """
            <html><head></head><body>
            <div id="comments"><ol class="comment-list"><li><p>Only in the markup.</p></li></ol></div>
            </body></html>
            """
        let transport = StubTransport(html(noAPI))
        let outcome = try await CommentsFetcher(transport: transport).fetch(url)

        guard case .markup(let markup) = outcome else {
            Issue.record("expected the page's markup, got \(outcome)")
            return
        }
        #expect(markup.contains("Only in the markup."))
        #expect(await transport.requestCount == 1)
    }

    // MARK: - Reusing discovery

    /// The saving the loader's cache exists for: re-opening an article re-reads the discussion
    /// without re-reading the page it was found on.
    @Test("A remembered discovery costs one request instead of two")
    func reusesDiscovery() async throws {
        let transport = StubTransport([
            html(wordPressPage),
            json("[\(commentJSON(id: 1))]"),
            json("[\(commentJSON(id: 1)), \(commentJSON(id: 2, date: "2026-09-03T09:00:00"))]"),
        ])
        let fetcher = CommentsFetcher(transport: transport)

        let discovery = try await fetcher.discover(url)
        _ = try await fetcher.comments(using: discovery, at: url)
        #expect(await transport.requestCount == 2)

        // The second read asks the API again — a discussion gains replies while the article above
        // it is being read, so the comments are the one part that must never be cached.
        let second = try await fetcher.comments(using: discovery, at: url)
        #expect(await transport.requestCount == 3)

        guard case .threads(let trees) = second else {
            Issue.record("expected threads, got \(second)")
            return
        }
        #expect(trees.map(\.id) == [1, 2])
    }

    // MARK: - Refusals

    @Test("A link that is not a web page has no comments to read")
    func refusesNonPages() async throws {
        let transport = StubTransport(
            .statusWithHeaders(200, headers: ["Content-Type": "application/pdf"], body: "%PDF-1.4")
        )
        await #expect(throws: CommentsFetcher.Failure.notAWebPage(contentType: "application/pdf")) {
            _ = try await CommentsFetcher(transport: transport).fetch(url)
        }
    }

    @Test("The page fetch is bounded")
    func refusesHugePages() async throws {
        let huge = String(repeating: "a", count: FullPageFetcher.maximumBytes + 1)
        let transport = StubTransport(html(huge))

        await #expect(throws: CommentsFetcher.Failure.tooLarge(bytes: FullPageFetcher.maximumBytes + 1)) {
            _ = try await CommentsFetcher(transport: transport).fetch(url)
        }
    }

    /// Identification and cookie policy are shared with the full-page fetch on purpose: this app
    /// has no session with the sites it reads and must not start building one.
    @Test("The page is fetched under the reader's own identity and without cookies")
    func fetchesPolitely() async throws {
        let transport = StubTransport([html(wordPressPage), json("[\(commentJSON(id: 1))]")])
        _ = try await CommentsFetcher(transport: transport).fetch(url)

        #expect(await transport.header("User-Agent", at: 0)?.contains("ReadRead") == true)
        #expect(await transport.requests[0].httpShouldHandleCookies == false)
        #expect(await transport.header("User-Agent", at: 1)?.contains("ReadRead") == true)
        #expect(await transport.requests[1].httpShouldHandleCookies == false)
    }
}
