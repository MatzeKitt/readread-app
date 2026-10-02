import Foundation
import ReadReadModel
import Testing

@testable import ReadReadUI

/// The links a row's context menu offers.
///
/// A row's links are inert so the row keeps its tap, which makes this list the only way to follow
/// one from the timeline. What matters is that it holds the links the post is *pointing at* — not
/// the mentions and hashtags Mastodon also marks up as anchors — and names each so it can be told
/// apart from the post's own Open in Browser.
@Suite("Status links")
struct StatusLinksTests {

    /// The shape Mastodon actually sends: the scheme and the tail of a long address in hidden spans.
    private let bareAddress = """
        <a href="https://example.com/a/long/path" target="_blank" rel="nofollow noopener">\
        <span class="invisible">https://</span><span class="ellipsis">example.com/a/long</span>\
        <span class="invisible">/path</span></a>
        """

    @Test("Every web link, in the order the post gives them")
    func linksInOrder() {
        let html = """
            <p>Read <a href="https://example.com/one">this</a> and \
            <a href="https://example.org/two">that</a>.</p>
            """

        let links = StatusLinks.links(inStatusHTML: html)

        #expect(links.map(\.url.absoluteString) == ["https://example.com/one", "https://example.org/two"])
    }

    /// A post addressed to five people would otherwise bury its one real link under five profiles.
    @Test("Mentions and hashtags are not offered")
    func mentionsAndHashtagsSkipped() {
        let html = """
            <p><span class="h-card"><a href="https://social.example/@ada" class="u-url mention">\
            @<span>ada</span></a></span> see <a href="https://example.com/post">this</a> \
            <a href="https://social.example/tags/swift" class="mention hashtag" rel="tag">\
            #<span>swift</span></a></p>
            """

        let links = StatusLinks.links(inStatusHTML: html)

        #expect(links.map(\.url.absoluteString) == ["https://example.com/post"])
    }

    /// Whole class tokens only. A class that merely contains the word is not a mention.
    @Test("A class containing the word is not a mention")
    func classTokensMatchedWhole() {
        let html = "<a href=\"https://example.com\" class=\"commentions\">site</a>"

        #expect(StatusLinks.links(inStatusHTML: html).count == 1)
    }

    @Test("The same destination is offered once")
    func duplicatesCollapse() {
        let html = """
            <a href="https://example.com/x">first</a> <a href="https://example.com/x">again</a>
            """

        let links = StatusLinks.links(inStatusHTML: html)

        #expect(links.count == 1)
        #expect(links.first?.title.hasPrefix("first") == true)
    }

    /// Open in Browser already covers the post itself.
    @Test("The post's own address is left out")
    func ownAddressExcluded() throws {
        let own = try #require(URL(string: "https://social.example/@ada/1"))
        let html = "<a href=\"https://social.example/@ada/1\">here</a> <a href=\"https://example.com\">there</a>"

        let links = StatusLinks.links(inStatusHTML: html, excluding: own)

        #expect(links.map(\.url.absoluteString) == ["https://example.com"])
    }

    @Test("Only web links are offered")
    func webLinksOnly() {
        let html = """
            <a href="mailto:ada@example.com">mail</a> <a href="javascript:alert(1)">x</a> \
            <a href="https://example.com">web</a>
            """

        #expect(StatusLinks.links(inStatusHTML: html).map(\.url.scheme) == ["https"])
    }

    /// The query string arrives entity-encoded, and opening the encoded form would request a
    /// different page.
    @Test("Entities in the address are decoded")
    func hrefEntitiesDecoded() {
        let html = "<a href=\"https://example.com/?a=1&amp;b=2\">page</a>"

        #expect(StatusLinks.links(inStatusHTML: html).first?.url.absoluteString == "https://example.com/?a=1&b=2")
    }

    /// The whole address, hidden spans included — and not the clipped form Mastodon's CSS shows,
    /// which would name a different page than the one it opens.
    @Test("A bare address is named as itself, without the scheme")
    func bareAddressTitle() {
        let links = StatusLinks.links(inStatusHTML: bareAddress)

        #expect(links.first?.title == "example.com/a/long/path")
    }

    /// A link's text can claim anything, so the menu says where it goes.
    @Test("Anchor text is followed by the host")
    func anchorTextGetsHost() {
        let html = "<a href=\"https://www.example.com/story\">this piece</a>"

        #expect(StatusLinks.links(inStatusHTML: html).first?.title == "this piece — example.com")
    }

    @Test("Anchor text that already names the host is left alone")
    func anchorTextNamingHost() {
        let html = "<a href=\"https://example.com/story\">on example.com</a>"

        #expect(StatusLinks.links(inStatusHTML: html).first?.title == "on example.com")
    }

    @Test("No markup, no links")
    func emptyMarkup() {
        #expect(StatusLinks.links(inStatusHTML: nil).isEmpty)
        #expect(StatusLinks.links(inStatusHTML: "").isEmpty)
        #expect(StatusLinks.links(inStatusHTML: "<p>Just words.</p>").isEmpty)
    }

    // MARK: - What the menu offers for an item

    private let linkingHTML = "<p>Read <a href=\"https://example.com/story\">this piece</a>.</p>"

    /// - Parameter warning: The spoiler text. Ingest stores a warned post's *warning* as the title
    ///   and leaves the excerpt empty — which is what `isBehindContentWarning` reads.
    private func item(kind: ItemKind = .status, warning: String? = nil) -> CachedItem {
        let key = SortKey(millis: 1_700_000_000_000, id: "s")
        return CachedItem(
            id: "s",
            sourceID: "mastodon:acct:home",
            accountID: UUID(),
            kind: kind,
            title: warning ?? "Read this piece.",
            contentHTML: linkingHTML,
            excerpt: warning == nil ? "Read this piece." : "",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key
        )
    }

    @Test("A post's links are offered")
    func postOffersLinks() {
        #expect(StatusLinks.links(offeredFor: item()).map(\.title) == ["this piece — example.com"])
    }

    /// Naming the links would print the hidden post's words into the menu — the one thing a
    /// content warning exists to prevent.
    @Test("Nothing is offered behind a content warning")
    func contentWarningOffersNothing() {
        #expect(StatusLinks.links(offeredFor: item(warning: "Spoilers")).isEmpty)
    }

    @Test("Nothing is offered for an article")
    func articleOffersNothing() {
        #expect(StatusLinks.links(offeredFor: item(kind: .article)).isEmpty)
    }
}
