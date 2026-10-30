import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// Formatting in the timeline, and the one case where formatting must not happen.
@Suite("Status text in the timeline")
@MainActor
struct StatusTextCacheTests {

    /// The bug this guards is about the *words*, not the attributes: the row used to show
    /// `plainText`, which dropped every anchor, so a post that was mostly a link read as a
    /// sentence with a hole in it.
    ///
    /// The link attribute itself is not asserted here. See `StatusTextCacheLinkTests` for the
    /// links, which are live in the row and in the pane alike.
    @Test("A post keeps the words its links were made of")
    func preservesLinkText() {
        let html = "<p>Read <a href=\"https://example.com\">this piece</a> and <em>then</em> reply.</p>"
        let text = StatusTextCache.shared.text(id: "a-\(UUID())", html: html, plain: "Read this piece and then reply.")

        #expect(String(text.characters).contains("Read this piece and then reply."))
    }

    @Test("Paragraph breaks survive")
    func preservesParagraphs() {
        let html = "<p>First.</p><p>Second.</p>"
        let text = StatusTextCache.shared.text(id: "b-\(UUID())", html: html, plain: "First. Second.")
        #expect(String(text.characters).contains("\n"))
    }

    @Test("Unparseable markup still shows the words")
    func fallsBackToPlainText() {
        let text = StatusTextCache.shared.text(id: "c-\(UUID())", html: nil, plain: "Just the words.")
        #expect(String(text.characters) == "Just the words.")
    }

    @Test("The same post is parsed once")
    func cachesByItemID() {
        let id = "d-\(UUID())"
        let first = StatusTextCache.shared.text(id: id, html: "<p>Hello</p>", plain: "Hello")
        // A second call with *different* markup returns the cached value, which is the observable
        // proof that nothing re-parsed.
        let second = StatusTextCache.shared.text(id: id, html: "<p>Something else</p>", plain: "x")
        #expect(first == second)
    }
}

/// A warned post is shown straight away, with its warning printed under it.
///
/// Easy to get wrong because ingest keeps the warning in `title`, which is the post's text for
/// every other post: read the wrong way, the row prints the warning as the post, or the post's
/// text twice and no warning at all.
@Suite("Content warnings in the timeline")
@MainActor
struct ContentWarningRowTests {

    private func status(title: String, excerpt: String, html: String) -> CachedItem {
        // An id of its own per row, because the parse cache is keyed by it and shared.
        let id = "cw-\(UUID())"
        let key = SortKey(millis: 1_700_000_000_000, id: id)
        return CachedItem(
            id: id,
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: .status,
            title: title,
            contentHTML: html,
            excerpt: excerpt,
            publishedAt: .now,
            sortKey: key,
            ingestKey: key
        )
    }

    @Test("A warned post shows the post, and its warning separately")
    func warnedPostShowsItsContent() {
        // Ingest writes a warned status this way: the spoiler as the title, and an empty excerpt.
        let item = status(
            title: "CW: election",
            excerpt: "",
            html: "<p>The hidden opinion nobody asked for.</p>"
        )
        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(row.contentWarningForTesting == "CW: election")
        let shown = String(row.statusTextForTesting.characters)
        #expect(shown.contains("hidden opinion"))
        #expect(!shown.contains("CW: election"))
    }

    @Test("An ordinary post shows its formatted content")
    func ordinaryPostShowsContent() {
        let item = status(
            title: "Plain fallback",
            excerpt: "Some words about a thing.",
            html: "<p>Some <strong>words</strong> about a thing.</p>"
        )
        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(row.contentWarningForTesting == nil)
        #expect(String(row.statusTextForTesting.characters).contains("Some words about a thing."))
    }
}
