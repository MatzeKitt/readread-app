import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Rendering a Read Later snapshot.
///
/// `ReadLaterEntry` exists so a saved item survives the cache being pruned, and nothing ever read
/// the snapshot back: the pane resolved the entry's id to a `CachedItem` and rendered *that*, so an
/// entry with no cached item — every entry synced from another device, and every entry whose item
/// has aged out — showed an empty pane. These cover the document the snapshot now produces.
@Suite("Archived item document")
struct ArchivedItemTests {

    private func entry(
        kind: ItemKind = .article,
        title: String = "A fine widget",
        excerpt: String = "The first line of it.",
        archivedHTML: String? = nil
    ) -> ReadLaterEntry {
        ReadLaterEntry(
            itemID: "freshrss:\(UUID().uuidString):1f2e",
            sourceID: "freshrss:acct:feed/1",
            accountID: UUID(),
            kind: kind,
            title: title,
            sourceTitle: "Daring Fireball",
            excerpt: excerpt,
            publishedAt: Date(millisecondsSinceEpoch: 1_700_000_000_000),
            sortKey: SortKey(millis: 1_700_000_000_000, id: "1f2e"),
            archivedHTML: archivedHTML
        )
    }

    private func document(for entry: ReadLaterEntry, notice: String? = nil) -> String {
        ReaderDocument.html(
            for: ReaderDocument.Subject(
                title: entry.kind == .status ? nil : entry.title,
                authorName: entry.sourceTitle,
                publishedAt: entry.publishedAt,
                contentHTML: entry.archivedHTML ?? ReaderDocument.paragraphs(
                    from: entry.excerpt.isEmpty ? entry.title : entry.excerpt
                )
            ),
            notice: notice
        )
    }

    /// The whole point of `archivesReadLaterContent`: the body kept at save time is what is read
    /// back, months later, with the feed long since having dropped the article.
    @Test("A saved body is what gets rendered")
    func savedBodyIsRendered() {
        let html = document(for: entry(archivedHTML: "<p>Every word of it.</p>"))

        #expect(html.contains("<p>Every word of it.</p>"))
        #expect(html.contains("A fine widget"))
    }

    /// Saved without an offline copy, the excerpt is all there is — three lines where an article
    /// should be, which needs saying rather than looking like a failed load.
    @Test("Without a saved body the excerpt is shown, as text")
    func excerptFallsBack() {
        let html = document(
            for: entry(excerpt: "Sizes are given as 5 < 6 & up."),
            notice: "Only the saved summary is left."
        )

        #expect(html.contains("<p>Sizes are given as 5 &lt; 6 &amp; up.</p>"))
        #expect(html.contains("Only the saved summary is left."))
        #expect(html.contains("class=\"notice\""))
    }

    /// A post's `title` is the post's own text — ingest puts it there — so setting it as the
    /// heading would print the post twice, once in headline type.
    @Test("A saved post gets no heading")
    func postHasNoHeading() {
        let post = entry(kind: .status, title: "Just tried the new thing. It is fine.", excerpt: "Just tried the new thing. It is fine.")
        let html = document(for: post)

        #expect(!html.contains("<h1>"))
        #expect(html.contains("Just tried the new thing."))
    }

    @Test("An article keeps its heading")
    func articleHasHeading() {
        #expect(document(for: entry()).contains("<h1>A fine widget</h1>"))
    }

    /// Blank lines are paragraph breaks and single newlines are line breaks — an excerpt is text,
    /// and rendering it as one run would collapse a saved post into a wall.
    @Test("Text becomes paragraphs and line breaks")
    func textStructure() {
        let markup = ReaderDocument.paragraphs(from: "First para.\n\nSecond line one.\nLine two.")

        #expect(markup.contains("<p>First para.</p>"))
        #expect(markup.contains("<p>Second line one.<br>Line two.</p>"))
    }

    /// The excerpt comes from a feed, so it is not to be trusted as markup: a `<` in it would
    /// otherwise break the document around it.
    @Test("Text is escaped, never rendered as markup")
    func textIsEscaped() {
        let markup = ReaderDocument.paragraphs(from: "<script>alert(1)</script>")

        #expect(!markup.contains("<script>"))
        #expect(markup.contains("&lt;script&gt;"))
    }

    /// A content warning leaves the excerpt empty on purpose — the warning is in `title`, and it
    /// is the only text the snapshot has.
    @Test("A post behind a content warning falls back to its warning")
    func contentWarningFallsBack() {
        let warned = entry(kind: .status, title: "Politics", excerpt: "")
        let html = document(for: warned)

        #expect(html.contains("<p>Politics</p>"))
    }
}
