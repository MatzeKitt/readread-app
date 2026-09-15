import Foundation
import Testing

@testable import ReadReadSupport

@Suite("HTMLText")
struct HTMLTextTests {

    @Test("Tags are stripped and text preserved")
    func stripsTags() {
        let html = "<p>Hello <strong>world</strong>.</p>"

        // The full stop stays attached: `</strong>` is inline, so it introduces no space.
        #expect(HTMLText.plainText(from: html) == "Hello world.")
    }

    /// Without treating block elements as word breaks, `<p>one</p><p>two</p>` collapses to
    /// "onetwo" — the single most visible excerpt bug.
    @Test("Block elements become word breaks")
    func blockElementsBreakWords() {
        #expect(HTMLText.plainText(from: "<p>one</p><p>two</p>") == "one two")
        #expect(HTMLText.plainText(from: "a<br>b") == "a b")
        #expect(HTMLText.plainText(from: "<li>x</li><li>y</li>") == "x y")
    }

    @Test("Inline elements do not introduce spaces")
    func inlineElementsDoNotBreakWords() {
        #expect(HTMLText.plainText(from: "un<em>frigging</em>believable") == "unfriggingbelievable")
    }

    /// Feed content routinely embeds tracking pixels, share widgets and inline SVG. Unwrapping
    /// these instead of dropping them would dump CSS and JavaScript into the excerpt.
    @Test("Script, style and svg contents are dropped entirely")
    func dropsNonProseContent() {
        let html = """
        <style>.a { color: red; }</style>Visible<script>var x = 1 < 2;</script>\
        <svg><path d="M0 0"/></svg>Text
        """

        #expect(HTMLText.plainText(from: html) == "VisibleText")
    }

    @Test("Whitespace and newlines collapse to single spaces")
    func collapsesWhitespace() {
        let html = "<div>\n    Lots\t\tof\n\n   space   \n</div>"

        #expect(HTMLText.plainText(from: html) == "Lots of space")
    }

    @Test("Named entities are decoded", arguments: [
        ("&amp;", "&"),
        ("&lt;tag&gt;", "<tag>"),
        ("&quot;quoted&quot;", "\"quoted\""),
        ("caf&eacute;", "caf&eacute;"),
        ("it&rsquo;s", "it’s"),
        ("a&hellip;", "a…"),
        ("&mdash;", "—"),
    ])
    func decodesNamedEntities(input: String, expected: String) {
        // `&eacute;` is intentionally absent from the table: unknown entities must be passed
        // through untouched rather than swallowed, so text is never silently lost.
        #expect(HTMLText.plainText(from: input) == expected)
    }

    @Test("Numeric entities are decoded", arguments: [
        ("&#65;", "A"),
        ("&#x41;", "A"),
        ("&#8230;", "…"),
        ("&#x2019;", "’"),
    ])
    func decodesNumericEntities(input: String, expected: String) {
        #expect(HTMLText.plainText(from: input) == expected)
    }

    /// Feed content is frequently malformed. None of these may crash or lose the visible text.
    @Test("Malformed markup degrades gracefully", arguments: [
        ("a < b", "a < b"),
        ("unterminated <p", "unterminated <p"),
        ("bare & ampersand", "bare & ampersand"),
        ("&notanentity;", "&notanentity;"),
        ("&#xZZ;", "&#xZZ;"),
        ("<>", ""),
        ("</p>alone", "alone"),
    ])
    func malformedMarkupDegradesGracefully(input: String, expected: String) {
        #expect(HTMLText.plainText(from: input) == expected)
    }

    @Test("An unclosed dropped tag does not swallow the rest of the document")
    func unclosedDroppedTagIsBounded() {
        // A truncated feed can end mid-<script>. Everything after it is genuinely inside the
        // script, so an empty excerpt is correct — what matters is that it terminates.
        #expect(HTMLText.plainText(from: "before<script>after") == "before")
    }

    @Test("Self-closing svg does not start a dropped region")
    func selfClosingSVGDoesNotDropFollowingText() {
        #expect(HTMLText.plainText(from: "a<svg/>b") == "ab")
    }

    /// Regression: parsing the body of a raw-text element as markup makes a `<` inside it consume
    /// the real closing tag while hunting for its own `>`, after which the scanner drops the whole
    /// remainder of the document. A single `if (a < b)` in an embedded script silently emptied the
    /// excerpt for every item from that feed.
    @Test("A '<' inside script or style does not swallow the closing tag", arguments: [
        ("<script>if (1 < 2) {}</script>kept", "kept"),
        ("<style>a[x<y]{}</style>kept", "kept"),
        ("<script>var a = '</scr' + 'ipt>';</script>kept", "kept"),
        ("pre<script>1<2</script>mid<script>3<4</script>post", "premidpost"),
    ])
    func rawTextElementsDoNotSwallowClosingTag(input: String, expected: String) {
        #expect(HTMLText.plainText(from: input) == expected)
    }

    @Test("A tag whose name merely starts with a dropped tag's name is not mistaken for its close")
    func closingTagRequiresADelimiter() {
        // `</scriptfoo>` must not end the `<script>` region, or content would leak through.
        #expect(HTMLText.plainText(from: "<script>x</scriptfoo>y</script>kept") == "kept")
    }

    @Test("Dropped regions are skipped without introducing a word break")
    func droppedRegionsDoNotIntroduceSpaces() {
        #expect(HTMLText.plainText(from: "Visi<style>.a{}</style>ble") == "Visible")
    }

    @Test("Empty and whitespace-only input yields an empty string", arguments: ["", "   ", "<p></p>", "\n\t"])
    func emptyInputYieldsEmptyString(input: String) {
        #expect(HTMLText.plainText(from: input).isEmpty)
    }

    // MARK: - Excerpts

    @Test("Short text is returned without an ellipsis")
    func shortTextIsNotTruncated() {
        let excerpt = HTMLText.excerpt(from: "<p>Short.</p>", limit: 50)

        #expect(excerpt == "Short.")
        #expect(!excerpt.hasSuffix("…"))
    }

    @Test("Truncation happens on a word boundary")
    func truncatesOnWordBoundary() {
        let excerpt = HTMLText.truncating("the quick brown fox jumps", to: 15)

        #expect(excerpt == "the quick brown…")
        // The word boundary must not be crossed: no partial word before the ellipsis.
        #expect(!excerpt.dropLast().hasSuffix("f"))
    }

    /// A single long token — a URL with no spaces — has no boundary to back up to, and backing up
    /// to the start would return just an ellipsis.
    @Test("A single long token is hard-cut rather than reduced to nothing")
    func singleLongTokenIsHardCut() {
        let url = String(repeating: "a", count: 100)
        let excerpt = HTMLText.truncating(url, to: 20)

        #expect(excerpt.count == 21)
        #expect(excerpt.hasSuffix("…"))
    }

    @Test("A zero or negative limit yields an empty string", arguments: [0, -1])
    func nonPositiveLimitYieldsEmptyString(limit: Int) {
        #expect(HTMLText.truncating("anything", to: limit).isEmpty)
    }

    @Test("Excerpting is fast enough to run over a whole ingest page")
    func excerptingIsFastEnoughForIngest() {
        // Guards the reason this is hand-rolled at all. A realistic long article, 200 times over,
        // which is roughly two ingest pages' worth.
        let article = String(
            repeating: "<p>Some <em>reasonably</em> typical paragraph text with an &amp; entity.</p>\n",
            count: 60
        )

        let started = ContinuousClock.now
        for _ in 0..<200 {
            _ = HTMLText.excerpt(from: article)
        }
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(2), "excerpting 200 articles took \(elapsed)")
    }
}
