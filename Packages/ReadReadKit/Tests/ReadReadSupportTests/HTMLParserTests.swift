import Foundation
import Testing

@testable import ReadReadSupport

/// The parser only has to be good enough to score against, so most of it is not worth pinning.
/// These are the cases where being wrong is silent — the tree still parses, it is simply the wrong
/// tree, and the damage only shows up as a bad extraction three layers away.
@Suite("HTMLParser")
struct HTMLParserTests {

    private func find(_ name: String, in root: HTMLElement) -> [HTMLElement] {
        root.descendants.filter { $0.name == name }
    }

    @Test("An angle bracket inside a quoted attribute does not end the tag")
    func quotedAngleBracketsDoNotEndTags() throws {
        // Found on a live Wikipedia page: Parsoid stores template source in `data-mw`, brackets and
        // all. Cutting the tag at the first `>` left the rest of the attribute — a page's worth of
        // JSON — parsed as body text, which then read as the densest prose on the page.
        let html = #"<div data-mw='{"wt":"<code>x</code>"}' id="real"><p>Body text here.</p></div>"#
        let root = HTMLParser.parse(html)

        let div = try #require(find("div", in: root).first)
        #expect(div.attributes["id"] == "real")
        #expect(div.text == "Body text here.")
        #expect(!root.descendants.contains { $0.name == "code" })
    }

    @Test("An unclosed paragraph does not swallow the blocks after it")
    func unclosedParagraphCloses() throws {
        // Legal HTML and extremely common. Without the implicit close every following block nests
        // inside the first paragraph, the tree collapses to one candidate, and density scoring has
        // nothing left to compare.
        let root = HTMLParser.parse("<div><p>One<p>Two<div>Three</div></div>")
        let paragraphs = find("p", in: root)

        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].text == "One")
        #expect(paragraphs[1].text == "Two")
        #expect(find("div", in: root).count == 2)
    }

    @Test("A stray closing tag is ignored rather than unwinding the document")
    func strayCloseTagIsIgnored() throws {
        let root = HTMLParser.parse("<div><p>One</span></p><p>Two</p></div>")
        #expect(find("p", in: root).count == 2)
        #expect(find("div", in: root).first?.text == "One Two")
    }

    @Test("A '<' inside a script body does not derail the parse")
    func scriptBodyIsRawText() throws {
        let root = HTMLParser.parse("<div><script>if (a < b) { x(); }</script><p>After.</p></div>")
        #expect(find("p", in: root).first?.text == "After.")
    }

    @Test("Attributes parse in every form they are written in")
    func attributeForms() throws {
        let root = HTMLParser.parse(#"<img src=plain.png alt="A quote" title='single' hidden data-x=1>"#)
        let img = try #require(find("img", in: root).first)

        #expect(img.attributes["src"] == "plain.png")
        #expect(img.attributes["alt"] == "A quote")
        #expect(img.attributes["title"] == "single")
        #expect(img.attributes["hidden"] == "")
        #expect(img.attributes["data-x"] == "1")
    }

    @Test("A void element does not become a parent")
    func voidElementsDoNotNest() throws {
        let root = HTMLParser.parse("<p>One<br>Two<img src=x>Three</p>")
        let paragraph = try #require(find("p", in: root).first)

        // `<br>` is a word break and `<img>` is inline, so the text either side of the image
        // stays joined — that asymmetry is what the breaking-tag set is for.
        #expect(paragraph.text == "One TwoThree")
        #expect(paragraph.childElements.count == 2)
    }

    @Test("List items close each other")
    func listItemsClose() throws {
        let root = HTMLParser.parse("<ul><li>One<li>Two<li>Three</ul>")
        #expect(find("li", in: root).map(\.text) == ["One", "Two", "Three"])
    }
}
