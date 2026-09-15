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
    /// The link attribute itself is deliberately not here any more — a row's links are stripped so
    /// they take the row's own colour and leave the row's tap alone. See `StatusTextCacheLinkTests`
    /// for that rule, and for the pane keeping its links.
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

/// The content warning is consent, and the timeline is where it is easiest to break: the row shows
/// the *warning* as its text, and rendering the post's markup instead would print the hidden post
/// straight into the list. The first version of the formatting change did exactly that.
@Suite("Content warnings in the timeline")
@MainActor
struct ContentWarningRowTests {

    private func status(title: String, excerpt: String, html: String) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "cw")
        return CachedItem(
            id: "cw",
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

    @Test("A warned post shows the warning, never the post")
    func warnedPostHidesItsContent() {
        // Ingest writes a warned status this way: the spoiler as the title, and an empty excerpt
        // precisely so the list can show one without the other.
        let item = status(
            title: "CW: election",
            excerpt: "",
            html: "<p>The hidden opinion nobody asked for.</p>"
        )
        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(row.hasContentWarningForTesting)
        let shown = String(row.statusTextForTesting.characters)
        #expect(shown == "CW: election")
        #expect(!shown.contains("hidden opinion"))
    }

    @Test("An ordinary post shows its formatted content")
    func ordinaryPostShowsContent() {
        let item = status(
            title: "Plain fallback",
            excerpt: "Some words about a thing.",
            html: "<p>Some <strong>words</strong> about a thing.</p>"
        )
        let row = ItemRow(item: item, showsLateArrival: false)

        #expect(!row.hasContentWarningForTesting)
        #expect(String(row.statusTextForTesting.characters).contains("Some words about a thing."))
    }
}
