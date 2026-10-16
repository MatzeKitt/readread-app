import Foundation
import Testing

@testable import ReadReadSupport

@Suite("DoubledURL")
struct DoubledURLTests {

    /// Verbatim from heyeased.weebly.com's feed, which is where this was found (REA-29).
    @Test("A Weebly CDN host glued onto an absolute image URL is cut off")
    func repairsWeeblyImage() {
        let html = """
        <div><img src="https://49114053-221246053734753775.preview.editmysite.comhttps://heyeased.weebly.com\
        /uploads/4/9/1/1/49114053/addedloading1_orig.png" width="300" height="240" alt="1"></div>
        """

        #expect(DoubledURL.repairing(html) == """
        <div><img src="https://heyeased.weebly.com/uploads/4/9/1/1/49114053/addedloading1_orig.png" \
        width="300" height="240" alt="1"></div>
        """)
    }

    @Test("Every doubled URL in the markup is repaired, whatever the schemes")
    func repairsEveryOccurrence() {
        let html = #"<img src="http://cdn.example.comhttps://a.example/1.png"><img src="HTTPS://cdn.example.comhttp://b.example/2.png">"#

        #expect(DoubledURL.repairing(html) == #"<img src="https://a.example/1.png"><img src="http://b.example/2.png">"#)
    }

    /// The host ends at the first slash, so a URL carried in another's path or query is not a
    /// doubled one and must survive untouched.
    @Test("A URL that merely contains another URL is left alone", arguments: [
        "https://share.example/?url=https://a.example/post",
        "https://web.archive.org/web/2026/https://a.example/post",
        "<p>See https://a.example and https://b.example.</p>",
        "<img src=\"/uploads/relative.png\">",
    ])
    func leavesOrdinaryURLsAlone(_ text: String) {
        #expect(DoubledURL.repairing(text) == text)
    }

    @Test("The full-page sanitiser loads the inner URL")
    func sanitizerRepairs() {
        let document = HTMLParser.parse(
            #"<p><img src="https://cdn.example.comhttps://site.example/a.png" alt="A"></p>"#
        )
        let html = HTMLSanitizer.sanitize(document, baseURL: URL(string: "https://site.example/post"))

        #expect(html.contains(#"<img alt="A" src="https://site.example/a.png">"#))
    }
}
