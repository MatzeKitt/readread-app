import Foundation
import Testing

@testable import ReadReadSupport

/// Discovery is the half of the comments feature that decides whether it works at all: everything
/// downstream is a fetch and a rendering, and both are unreachable if a page's markers are not
/// read correctly. The markup fallback is tested here too, because what it has to remove is not
/// obvious from the code that removes it.
@Suite("WordPressComments")
struct WordPressCommentsTests {

    private let base = URL(string: "https://example.com/2026/09/widgets/")!

    private func page(head: String, body: String = "", bodyClass: String = "post-template postid-482") -> String {
        """
        <!doctype html>
        <html><head><title>Widgets</title>\(head)</head>
        <body class="\(bodyClass)">\(body)</body></html>
        """
    }

    // MARK: - REST discovery

    @Test("The JSON alternate link gives the API root and the post id at once")
    func discoversFromAlternateLink() throws {
        let html = page(head: """
            <link rel="alternate" type="application/json" href="https://example.com/wp-json/wp/v2/posts/482">
            """)

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.postID == 482)
        #expect(endpoint.collectionURL.absoluteString == "https://example.com/wp-json/wp/v2/comments")
    }

    /// Where permalinks are not pretty, the same API is addressed through a query parameter. It is
    /// the same request and has to reduce to the same endpoint.
    @Test("The query-parameter form of the API resolves identically")
    func discoversRestRouteForm() throws {
        let html = page(head: """
            <link rel="alternate" type="application/json" href="https://example.com/?rest_route=/wp/v2/posts/482">
            """)

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.postID == 482)

        let url = try #require(endpoint.requestURL(page: 1))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "rest_route", value: "/wp/v2/comments")))
        #expect(items.contains(URLQueryItem(name: "post", value: "482")))
    }

    /// The older marker: core's API root plus the `?p=` shortlink it also emits.
    @Test("The API root and the shortlink together are enough")
    func discoversFromRootAndShortlink() throws {
        let html = page(head: """
            <link rel="https://api.w.org/" href="https://example.com/wp-json/">
            <link rel="shortlink" href="https://example.com/?p=482">
            """)

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.postID == 482)
        #expect(endpoint.collectionURL.absoluteString == "https://example.com/wp-json/wp/v2/comments")
    }

    /// `body_class()` is the last resort, and the one every theme carries whether it means to.
    @Test("The body class supplies the post id when no shortlink does")
    func discoversPostIDFromBodyClass() throws {
        let html = page(head: """
            <link rel="https://api.w.org/" href="https://example.com/wp-json/">
            """)

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.postID == 482)
    }

    @Test("A WordPress page carries its id under either spelling")
    func discoversPageID() throws {
        let html = page(
            head: #"<link rel="https://api.w.org/" href="https://example.com/wp-json/">"#,
            bodyClass: "page page-id-77"
        )

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.postID == 77)
    }

    @Test("A page with no WordPress markers has no endpoint")
    func ignoresNonWordPressPages() {
        let html = page(head: "<link rel=\"canonical\" href=\"https://example.com/x\">", bodyClass: "site")
        #expect(WordPressComments.endpoint(in: html, baseURL: base) == nil)
    }

    /// An API root with no post id is not enough: `wp/v2/comments` with no `post` returns the
    /// site's *entire* comment history, which is emphatically not this article's discussion.
    @Test("An API root alone is not enough")
    func refusesRootWithoutPostID() {
        let html = page(
            head: #"<link rel="https://api.w.org/" href="https://example.com/wp-json/">"#,
            bodyClass: "site no-id-here"
        )
        #expect(WordPressComments.endpoint(in: html, baseURL: base) == nil)
    }

    @Test("A relative API link resolves against the article's own URL")
    func resolvesRelativeLinks() throws {
        let html = page(head: #"<link rel="alternate" type="application/json" href="/wp-json/wp/v2/posts/9">"#)

        let endpoint = try #require(WordPressComments.endpoint(in: html, baseURL: base))
        #expect(endpoint.collectionURL.absoluteString == "https://example.com/wp-json/wp/v2/comments")
        #expect(endpoint.postID == 9)
    }

    // MARK: - Request shape

    @Test("A request asks for one page of comments on one post, oldest first")
    func buildsRequest() throws {
        let endpoint = WordPressComments.Endpoint(
            collectionURL: URL(string: "https://example.com/wp-json/wp/v2/comments")!,
            postID: 482
        )
        let url = try #require(endpoint.requestURL(page: 2))
        let items = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        #expect(items["post"] == "482")
        #expect(items["page"] == "2")
        #expect(items["per_page"] == "100")
        #expect(items["order"] == "asc")
        // Without this the response carries `meta`, `_links` and a second copy of every body.
        #expect(items["_fields"]?.contains("author_avatar_urls") == true)
    }

    /// A hundred is the server's ceiling and asking past it is a 400, so the clamp has to be here
    /// rather than in the caller's head.
    @Test("Page size is clamped to what the API accepts")
    func clampsPageSize() throws {
        let endpoint = WordPressComments.Endpoint(
            collectionURL: URL(string: "https://example.com/wp-json/wp/v2/comments")!,
            postID: 1
        )
        let url = try #require(endpoint.requestURL(page: 1, perPage: 500))
        #expect(url.absoluteString.contains("per_page=100"))
    }

    // MARK: - Markup fallback

    private var themedPage: String {
        """
        <!doctype html><html><body>
        <article><p>The article itself.</p></article>
        <div id="comments" class="comments-area">
          <h2 class="comments-title">3 thoughts on widgets</h2>
          <ol class="comment-list">
            <li class="comment">
              <article class="comment-body">
                <footer><b class="fn">Jo</b> <time>2 September 2026</time></footer>
                <p>The first thought.</p>
                <div class="reply"><a class="comment-reply-link" href="#respond">Reply</a></div>
              </article>
              <ol class="children">
                <li class="comment"><article class="comment-body"><p>A reply to it.</p></article></li>
              </ol>
            </li>
          </ol>
          <nav class="comment-navigation"><a href="?cpage=2">Older comments</a></nav>
          <div id="respond" class="comment-respond">
            <h3 class="comment-reply-title">Leave a Reply</h3>
            <form action="/wp-comments-post.php">
              <label for="comment">Comment</label>
              <textarea id="comment"></textarea>
              <input type="submit" value="Post Comment">
            </form>
          </div>
        </div>
        </body></html>
        """
    }

    @Test("The page's own comments are found in #comments")
    func extractsThemedComments() throws {
        let markup = try #require(WordPressComments.markup(in: themedPage, baseURL: base))
        #expect(markup.contains("The first thought."))
        #expect(markup.contains("A reply to it."))
        // The nested list survives, which is the only thing carrying who replied to whom once the
        // theme's classes have been stripped.
        #expect(markup.contains("<ol>"))
    }

    /// The part the sanitiser cannot do. It strips attributes, not meaning — and an unknown element
    /// there is *unwrapped*, so a `<form>` left in place contributes its labels and button captions
    /// as prose in the middle of the discussion.
    @Test("The reply form, the Reply links and the pagination are removed")
    func removesFurniture() throws {
        let markup = try #require(WordPressComments.markup(in: themedPage, baseURL: base))
        #expect(!markup.contains("Leave a Reply"))
        #expect(!markup.contains("Post Comment"))
        #expect(!markup.contains("Older comments"))
        #expect(!markup.lowercased().contains("<form"))
        #expect(!markup.lowercased().contains("<textarea"))
        // The per-comment Reply link acts on a page nobody is looking at.
        #expect(!markup.contains(">Reply<"))
    }

    @Test("An article with no comment section yields no markup")
    func noContainerNoMarkup() {
        let html = "<html><body><article><p>Just the article.</p></article></body></html>"
        #expect(WordPressComments.markup(in: html, baseURL: base) == nil)
    }

    /// A post open for comments but with none yet renders an empty container. There is nothing to
    /// show, and a heading with a rule above it over nothing is worse than no section.
    @Test("An empty comment section yields no markup")
    func emptyContainerNoMarkup() {
        let html = """
            <html><body><div id="comments">
            <div id="respond"><form><input type="submit" value="Post Comment"></form></div>
            </div></body></html>
            """
        #expect(WordPressComments.markup(in: html, baseURL: base) == nil)
    }

    @Test("Nothing executable survives the fallback")
    func fallbackIsInert() throws {
        let html = """
            <html><body><div id="comments"><ol class="comment-list">
            <li><p onclick="steal()">Hello</p>
            <script>steal()</script>
            <img src="x" onerror="steal()">
            <a href="javascript:steal()">tap</a></li>
            </ol></div></body></html>
            """
        let markup = try #require(WordPressComments.markup(in: html, baseURL: base))
        #expect(markup.contains("Hello"))
        #expect(!markup.contains("steal"))
        #expect(!markup.lowercased().contains("onclick"))
        #expect(!markup.lowercased().contains("javascript:"))
    }

    // MARK: - Threading

    private func comment(_ id: Int, parent: Int = 0, at offset: TimeInterval = 0) -> WordPressComment {
        WordPressComment(
            id: id,
            parentID: parent,
            authorName: "Author \(id)",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            contentHTML: "<p>Comment \(id)</p>"
        )
    }

    @Test("Replies nest under what they reply to")
    func buildsTrees() throws {
        let trees = WordPressComment.trees(from: [
            comment(1, at: 0),
            comment(2, parent: 1, at: 10),
            comment(3, parent: 2, at: 20),
            comment(4, at: 30),
        ])

        #expect(trees.map(\.id) == [1, 4])
        #expect(trees[0].replies.map(\.id) == [2])
        #expect(trees[0].replies[0].replies.map(\.id) == [3])
        #expect(trees[1].replies.isEmpty)
    }

    /// Every level is sorted here rather than trusted from the server: the API is asked for
    /// ascending order, but the comments arrive across several pages and a reply posted mid-fetch
    /// lands wherever it lands.
    @Test("Each level reads oldest first regardless of arrival order")
    func sortsEachLevel() {
        let trees = WordPressComment.trees(from: [
            comment(3, parent: 1, at: 30),
            comment(1, at: 0),
            comment(2, parent: 1, at: 20),
        ])

        #expect(trees[0].replies.map(\.id) == [2, 3])
    }

    /// A moderator deleting a comment that had replies, or a reply whose parent fell on the other
    /// side of the page cap. Dropping it would silently lose what someone wrote.
    @Test("A reply whose parent is missing is promoted rather than dropped")
    func promotesOrphans() {
        let trees = WordPressComment.trees(from: [
            comment(1, at: 0),
            comment(9, parent: 404, at: 10),
        ])

        #expect(trees.map(\.id) == [1, 9])
    }

    /// `parent` is an id out of somebody's database, not a proof that the graph is a tree. Without
    /// the visited set this recurses until the stack runs out.
    @Test("A parent cycle terminates and loses nothing")
    func survivesCycles() {
        let trees = WordPressComment.trees(from: [
            comment(1, parent: 2, at: 0),
            comment(2, parent: 1, at: 10),
        ])

        // Terminating is only half of it. Every member of a cycle has a parent that exists, so
        // none of them is a child of the root — and a walk that only descends from the root
        // returned both of these as *nothing at all*, which is how this assertion earned its keep.
        let ids = trees.flatMap { [$0.id] + $0.replies.map(\.id) }
        #expect(ids.sorted() == [1, 2])
    }

    @Test("No comments makes no trees")
    func emptyIsEmpty() {
        #expect(WordPressComment.trees(from: []).isEmpty)
    }
}
