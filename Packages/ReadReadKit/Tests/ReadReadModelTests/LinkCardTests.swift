import Foundation
import ReadReadModel
import Testing

/// What a link preview will and will not show, and the three states of the column behind it.
@Suite("Link card")
struct LinkCardTests {

    private func card(
        url: String = "https://www.example.com/a-piece?utm=1",
        title: String = "A headline",
        summary: String = "A blurb.",
        image: String? = "https://cdn.example.com/og.png"
    ) -> LinkCard {
        LinkCard(urlString: url, title: title, summary: summary, imageURLString: image)
    }

    // MARK: - What is worth drawing

    /// Instances do produce cards with nothing in them, for a link whose target answered with no
    /// usable metadata. An empty box under a post reads as a bug.
    @Test("A card with no headline is not worth a box")
    func headlessCardIsNotShowable() {
        #expect(!card(title: "").isShowable)
    }

    @Test("A card with no blurb still is")
    func blurblessCardIsShowable() {
        #expect(card(summary: "").isShowable)
    }

    @Test("A card whose URL will not parse is not")
    func unparseableURLIsNotShowable() {
        #expect(!card(url: "").isShowable)
    }

    // MARK: - The picture

    /// The one part of a card that causes a request from the reader's own device, so it does not
    /// go out in the clear.
    @Test("A picture served over plain http is refused")
    func insecureImageRefused() {
        #expect(card(image: "http://cdn.example.com/og.png").imageURL == nil)
    }

    @Test("A picture served over https is used")
    func secureImageUsed() {
        #expect(card().imageURL?.absoluteString == "https://cdn.example.com/og.png")
    }

    @Test("No picture is an ordinary case, not a failure")
    func missingImageIsFine() {
        let none = card(image: nil)
        #expect(none.imageURL == nil)
        #expect(none.isShowable)
    }

    // MARK: - The site

    /// What a tap would actually reach, which is the useful thing to print beside somebody else's
    /// headline — a link's own text can claim anything.
    @Test("The host is shown without its www")
    func hostDropsWWW() {
        #expect(card().hostLabel == "example.com")
        #expect(card(url: "https://blog.example.org/x").hostLabel == "blog.example.org")
    }

    @Test("A URL with no host has no label")
    func hostlessURLHasNoLabel() {
        #expect(card(url: "not a url at all").hostLabel == nil)
    }

    // MARK: - The column's three states

    private func item(kind: ItemKind, card: LinkCard?) -> CachedItem {
        let key = SortKey(millis: 1, id: "i")
        return CachedItem(
            id: "i",
            sourceID: "s",
            accountID: UUID(),
            kind: kind,
            title: "t",
            publishedAt: .now,
            sortKey: key,
            ingestKey: key,
            linkCard: card
        )
    }

    @Test("A card round-trips through the row's columns")
    func cardRoundTrips() {
        let row = item(kind: .status, card: card())

        #expect(row.linkCard == card())
        #expect(row.cardURLString == "https://www.example.com/a-piece?utm=1")
    }

    /// The sentinel that keeps the backfill affordable. Most posts link to nothing, so "examined,
    /// no card" has to be a *stored answer* — otherwise every cardless post is re-decoded on every
    /// launch, for ever.
    @Test("A post with no card is recorded as examined")
    func statusWithoutCardIsExamined() {
        let row = item(kind: .status, card: nil)

        #expect(row.linkCard == nil)
        #expect(row.cardURLString == "")
    }

    /// An article has no notion of a card, so it must stay out of a backfill that only wants
    /// statuses — and nil is what keeps it out.
    @Test("An article is left unexamined rather than answered")
    func articleIsNotExamined() {
        let row = item(kind: .article, card: nil)

        #expect(row.cardURLString == nil)
    }

    /// Assigning nil later has to mean "examined, no card" and not revert the row to unexamined,
    /// or a post whose card the instance withdrew would be re-decoded on every launch.
    @Test("Clearing a card records an answer rather than forgetting the question")
    func clearingRecordsAnAnswer() {
        let row = item(kind: .status, card: card())
        row.linkCard = nil

        #expect(row.cardURLString == "")
        #expect(row.cardTitle == nil)
    }
}
