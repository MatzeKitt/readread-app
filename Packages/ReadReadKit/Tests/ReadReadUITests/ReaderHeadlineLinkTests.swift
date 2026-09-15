import Foundation
import Testing

@testable import ReadReadUI

/// The headline's link to the original, which replaced a toolbar button.
///
/// Worth pinning for two reasons. It is the *only* way to the original article now that "Open in
/// Browser" has gone from the reading pane, so a headline that quietly stops being a link is a
/// feature disappearing rather than a visual slip. And it puts a feed's own strings inside an HTML
/// attribute, which is the one place in this document where an escaping mistake turns text from a
/// stranger into markup this app wrote on their behalf.
@Suite("Reader headline link")
struct ReaderHeadlineLinkTests {

    private func html(title: String?, urlString: String?) -> String {
        ReaderDocument.html(
            for: ReaderDocument.Subject(
                title: title,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentHTML: "<p>Body.</p>",
                urlString: urlString
            )
        )
    }

    @Test("A headline with a link is wrapped in an anchor to it")
    func headlineLinks() {
        let markup = html(title: "A fine widget", urlString: "https://example.com/widget")

        #expect(markup.contains("<h1><a class=\"headline\" href=\"https://example.com/widget\">A fine widget</a></h1>"))
    }

    /// Some feeds publish no link at all. A dead anchor would look identical and do nothing, which
    /// is worse than plain text: the reader would keep clicking it.
    @Test("A headline with no link stays plain text")
    func headlineWithoutLinkStaysPlain() {
        #expect(html(title: "A fine widget", urlString: nil).contains("<h1>A fine widget</h1>"))
        #expect(html(title: "A fine widget", urlString: "").contains("<h1>A fine widget</h1>"))
    }

    /// A Mastodon post has no headline of its own — its text is in `title`, and setting that as an
    /// `<h1>` would print the post twice. Linking a heading that is not there must not invent one.
    @Test("A subject with no title has no heading to link")
    func noTitleHasNoHeading() {
        let markup = html(title: nil, urlString: "https://example.com/widget")

        #expect(!markup.contains("<h1"))
    }

    /// Both halves are escaped, and each is a separate way in: a quote in the *title* would close
    /// the anchor's text and let the rest be read as tags, and a quote in the *URL* would close the
    /// `href` attribute and let anything after it become attributes of this app's own anchor.
    ///
    /// Asserted as "the payload is still inside the attribute" rather than "the payload is absent",
    /// because escaped it *is* present — as the text `&quot; onclick=&quot;`, which is a strange
    /// URL and not an event handler.
    @Test("A quote in the title or the URL cannot escape the anchor")
    func quotesAreEscaped() {
        let markup = html(
            title: "The \"best\" widget <ever>",
            urlString: "https://example.com/a\" onclick=\"alert(1)"
        )

        #expect(markup.contains("href=\"https://example.com/a&quot; onclick=&quot;alert(1)\">"))
        #expect(!markup.contains("onclick=\""))
        #expect(!markup.contains("<ever>"))
        #expect(markup.contains("The &quot;best&quot; widget &lt;ever&gt;"))
    }

    /// A feed can publish anything as its canonical link, and this is the one anchor in the
    /// document that the app writes itself. A `javascript:` headline would be script the reader ran
    /// by clicking a title — so those are left as plain text, along with every other scheme that is
    /// not a page to visit.
    @Test("A headline whose link is not http or https stays plain text")
    func nonWebSchemesStayPlain() {
        for urlString in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "file:///etc/passwd", "not a url at all"] {
            let markup = html(title: "A fine widget", urlString: urlString)
            #expect(markup.contains("<h1>A fine widget</h1>"), "\(urlString) should not be linked")
            #expect(!markup.contains("a class=\"headline\""), "\(urlString) should not be linked")
        }
    }
}
