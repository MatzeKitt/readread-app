import Foundation
import SwiftUI
import Testing

@testable import ReadReadUI

/// Links in a timeline row, and in the reading pane.
///
/// A run carrying a `.link` attribute is drawn in the accent colour, which put a stripe of blue
/// through text that is otherwise the app's own greys — and, in a row, made the link a second tap
/// target on top of the row's. Repainting settles the first and dropping the attribute settles the
/// second, and together they leave a third question: with nothing to distinguish it, the anchor
/// text is invisible *as a link*, which reads oddly in a post that is mostly a URL. So the run is
/// underlined. It was contrast that did that job once, back when the row's text sat a step below
/// full — the underline is what replaced it when the text came up to meet the link.
///
/// What must survive is the words. The row used to show `plainText`, which threw the anchor text
/// away and left a post that was mostly a link reading as a bare sentence.
@Suite("Status text links")
@MainActor
struct StatusTextCacheLinkTests {

    private let html = "<p>Read <a href=\"https://example.com/post\">this piece</a> today.</p>"

    @Test("A row's text carries no links")
    func rowTextHasNoLinks() {
        let text = StatusTextCache.shared.text(id: "row-1", html: html, plain: "Read this piece today.")

        #expect(text.runs.allSatisfy { $0.link == nil })
    }

    /// The reading pane is where a post is actually read, and its links have to work.
    @Test("The reading pane keeps its links")
    func paneTextKeepsLinks() {
        let text = StatusTextCache.shared.fullText(id: "pane-1", html: html, plain: "Read this piece today.")

        #expect(text.runs.contains { $0.link != nil })
    }

    /// The whole reason the row shows formatted text rather than a flattened string.
    @Test("The anchor text is still there")
    func anchorTextSurvives() {
        let text = StatusTextCache.shared.text(id: "row-2", html: html, plain: "fallback")

        #expect(String(text.characters).contains("this piece"))
    }

    /// Structure is not link-ness and must not be collateral damage. A post's paragraph breaks are
    /// most of what makes a multi-paragraph post readable in a row.
    ///
    /// Emphasis is deliberately not asserted here: `MastodonMarkdown` strips every tag except the
    /// anchors, so `<em>` never reaches the parser in the first place and a test for it would pass
    /// or fail for reasons unrelated to links.
    @Test("Paragraph breaks survive having links stripped")
    func structureSurvives() {
        let source = "<p>First <a href=\"https://example.com\">link</a>.</p><p>Second.</p>"
        let text = StatusTextCache.shared.text(id: "row-3", html: source, plain: "First link. Second.")

        #expect(String(text.characters).contains("\n"))
        #expect(text.runs.allSatisfy { $0.link == nil })
    }

    /// The colour is the *only* thing left saying "link", so it has to land on exactly the anchor
    /// text and nowhere else. A run-merging mistake here would either colour the whole post or
    /// colour none of it, and both look deliberate.
    ///
    /// The colour itself is asserted rather than merely its presence, because the first version of
    /// this was `.secondary` at reduced opacity — which is *away* from full contrast, so in dark
    /// mode links came out dimmer than the sentence around them. A test for "has a colour" passes
    /// for both directions and would have caught nothing.
    @Test("A link is drawn at full contrast, and only the link")
    func linkRunIsHighlighted() {
        let text = StatusTextCache.shared.text(id: "row-5", html: html, plain: "Read this piece today.")

        let coloured = text.runs.filter { $0.foregroundColor != nil }
        #expect(coloured.count == 1)
        #expect(coloured.map { String(text[$0.range].characters) } == ["this piece"])
        #expect(coloured.first?.foregroundColor == .primary)

        // The rest carries no colour of its own, which is what lets it inherit the row's.
        #expect(text.runs.contains { $0.foregroundColor == nil })
    }

    /// The pane's links are the same colour as the row's, and that is the point: the identical
    /// post in the identical app should not change hue between the two columns. Left alone they
    /// came out in the accent colour, because a run carrying a `.link` is drawn in the tint.
    @Test("A pane link is drawn in the row's link colour")
    func paneLinkIsRecoloured() {
        let text = StatusTextCache.shared.fullText(id: "pane-2", html: html, plain: "Read this piece today.")

        let coloured = text.runs.filter { $0.foregroundColor != nil }
        #expect(coloured.map { String(text[$0.range].characters) } == ["this piece"])
        #expect(coloured.first?.foregroundColor == .primary)
    }

    /// The load-bearing one, in both columns. ``StatusTextCache/linkColor`` is now the same colour
    /// as the text it sits in — full contrast in the row and in the pane alike — so nothing but
    /// the underline separates a link from the sentence around it. In the pane that also means
    /// hiding something that actually does something, since those links are live.
    ///
    /// Asserted on the anchor run specifically, not merely somewhere in the string: underlining
    /// the whole post would satisfy a looser test and put a rule under every line.
    @Test("A link is underlined in the row and in the pane", arguments: [true, false])
    func linksAreUnderlined(inPane: Bool) {
        let text = inPane
            ? StatusTextCache.shared.fullText(id: "pane-3", html: html, plain: "Read this piece today.")
            : StatusTextCache.shared.text(id: "row-7", html: html, plain: "Read this piece today.")

        let underlined = text.runs.filter { $0.underlineStyle != nil }
        #expect(underlined.map { String(text[$0.range].characters) } == ["this piece"])
    }

    /// The underline marks links, not text. Assigning it across the whole string would put a rule
    /// under every post in the pane.
    @Test("A post without links is not underlined", arguments: [true, false])
    func plainPostIsNotUnderlined(inPane: Bool) {
        let source = "<p>No links at all here.</p>"
        let text = inPane
            ? StatusTextCache.shared.fullText(id: "pane-4", html: source, plain: "No links at all here.")
            : StatusTextCache.shared.text(id: "row-8", html: source, plain: "No links at all here.")

        #expect(text.runs.allSatisfy { $0.underlineStyle == nil })
        #expect(text.runs.allSatisfy { $0.foregroundColor == nil })
    }

    /// A post with no links must come out of this untouched — the dimming is applied per run, and
    /// a version that assigned across the whole string would quietly fade every post in the
    /// timeline.
    @Test("A post without links keeps the row's own colour")
    func plainPostIsNotDimmed() {
        let text = StatusTextCache.shared.text(
            id: "row-6",
            html: "<p>No links at all here.</p>",
            plain: "No links at all here."
        )

        #expect(text.runs.allSatisfy { $0.foregroundColor == nil })
    }
}
