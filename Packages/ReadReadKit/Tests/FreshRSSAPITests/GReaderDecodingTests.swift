import Foundation
import Testing

@testable import FreshRSSAPI

/// Decoding tests against fixtures shaped from the FreshRSS source (`greader.php` and
/// `FreshRSS_Entry::toGReader()`), rather than from the historic Google Reader documentation —
/// FreshRSS implements a subset with its own additions, and several documented fields are
/// commented out in its implementation.
@Suite("GReader decoding")
struct GReaderDecodingTests {

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
            // Without this the whole suite silently passes on zero assertions.
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }

    // MARK: - Subscriptions

    @Test("Subscription list decodes")
    func decodesSubscriptions() throws {
        let list = try JSONDecoder().decode(GReaderSubscriptionList.self, from: fixture("subscription-list"))

        #expect(list.subscriptions.count == 4)

        let first = list.subscriptions[0]
        #expect(first.id == "feed/1")
        #expect(first.feedID == "1")
        #expect(first.title == "Daring Fireball")
        #expect(first.folderName == "Apple")
        #expect(first.iconURLString == "https://rss.example.net/f.php?id=1")
        #expect(first.homepageURLString == "https://daringfireball.net/")
        #expect(first.frssPriority == "main")
    }

    /// FreshRSS emits `iconUrl` unconditionally and leaves it empty when it has no favicon, so
    /// emptiness has to mean the same as absence — otherwise every such feed tries to load `""`
    /// as an image URL on every row.
    @Test("An empty iconUrl is normalised to nil")
    func emptyIconURLIsNil() throws {
        let list = try JSONDecoder().decode(GReaderSubscriptionList.self, from: fixture("subscription-list"))

        #expect(list.subscriptions[1].iconURLString == nil)
        #expect(list.subscriptions[2].homepageURLString == nil)
    }

    @Test("A feed with no category has no folder")
    func uncategorisedFeedHasNoFolder() throws {
        let list = try JSONDecoder().decode(GReaderSubscriptionList.self, from: fixture("subscription-list"))

        #expect(list.subscriptions[2].categories.isEmpty)
        #expect(list.subscriptions[2].folderName == nil)
    }

    /// Category names are user-chosen free text. Deriving the name by splitting `user/-/label/…`
    /// on `/` would truncate any folder containing a slash.
    @Test("A folder name containing a slash survives")
    func folderNameWithSlashSurvives() throws {
        let list = try JSONDecoder().decode(GReaderSubscriptionList.self, from: fixture("subscription-list"))

        #expect(list.subscriptions[3].folderName == "News / Long Reads")
    }

    @Test("A category ref falls back to parsing its id when label is absent")
    func categoryRefFallsBackToID() throws {
        let ref = try JSONDecoder().decode(
            GReaderCategoryRef.self,
            from: Data(#"{"id":"user/-/label/News / Long Reads"}"#.utf8)
        )

        #expect(ref.folderName == "News / Long Reads")
    }

    // MARK: - Tags

    /// FreshRSS puts categories *and* user labels under the same `user/-/label/` prefix, so the
    /// `type` field is the only thing distinguishing a sidebar folder from a tag.
    @Test("Folders are distinguished from tags by type, not by id prefix")
    func foldersDistinguishedByType() throws {
        let list = try JSONDecoder().decode(GReaderTagList.self, from: fixture("tag-list"))

        let folders = list.tags.filter(\.isFolder).compactMap(\.folderName)
        #expect(folders == ["Apple", "News / Long Reads"])

        let tag = list.tags.first { $0.type == "tag" }
        #expect(tag?.folderName == "to-read")
        #expect(tag?.unreadCount == 4)
        #expect(tag?.isFolder == false)
    }

    @Test("Built-in state streams are not folders")
    func builtInStatesAreNotFolders() throws {
        let list = try JSONDecoder().decode(GReaderTagList.self, from: fixture("tag-list"))

        let states = list.tags.filter { $0.id.hasPrefix("user/-/state/") }
        #expect(states.count == 4)
        #expect(states.allSatisfy { !$0.isFolder })
        #expect(states.allSatisfy { $0.folderName == nil })
    }

    // MARK: - Stream contents

    @Test("Stream contents decode with the continuation cursor")
    func decodesStreamContents() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))

        #expect(page.items.count == 3)
        // Absence of `continuation` is how a walk knows it has reached the end, so its presence
        // here has to survive decoding intact.
        #expect(page.continuation == "1685459810234342")
    }

    @Test("Item fields and derived values decode")
    func decodesItemFields() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))
        let item = page.items[0]

        #expect(item.id == GReaderItemID(value: 1_685_681_150_315_536))
        #expect(item.title == "On the new design language")
        #expect(item.author == "John Gruber")
        #expect(item.linkURLString == "https://daringfireball.net/2026/09/design")
        #expect(item.originStreamID == "feed/1")
        #expect(item.contentHTML.contains("<em>hierarchy</em>"))
        #expect(item.publishedDate == Date(timeIntervalSince1970: 1_756_998_000))
    }

    /// `crawlTimeMsec` is the server's `date_added` and is the app's `ingestKey` source. Reading it
    /// wrong would break late-arrival detection and retention, both of which depend on knowing
    /// when an item actually arrived rather than when it claims to have been published.
    @Test("Server insertion time is read from crawlTimeMsec")
    func readsCrawlTimeMsec() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))

        #expect(page.items[0].ingestMillis == 1_756_999_000_000)
    }

    /// The two timestamps are the same instant at different scales. A server sending only
    /// `timestampUsec` must still yield a usable ingest time.
    @Test("Insertion time falls back to timestampUsec when crawlTimeMsec is absent")
    func fallsBackToTimestampUsec() throws {
        let item = try JSONDecoder().decode(GReaderItem.self, from: Data("""
        {
            "id": "tag:google.com,2005:reader/item/0000000000000001",
            "timestampUsec": "1756999000000000"
        }
        """.utf8))

        #expect(item.crawlTimeMsec == nil)
        #expect(item.ingestMillis == 1_756_999_000_000)
    }

    @Test("Enclosures decode, including one without a length")
    func decodesEnclosures() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))
        let enclosures = page.items[1].enclosure ?? []

        #expect(enclosures.count == 2)
        #expect(enclosures[0].type == "audio/mpeg")
        #expect(enclosures[0].length == 12_345_678)
        #expect(enclosures[1].length == nil)
    }

    @Test("An item with no author decodes")
    func itemWithoutAuthorDecodes() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))

        #expect(page.items[1].author == nil)
    }

    /// The back-dated fixture is the case the whole late-arrival design exists for: it arrived in
    /// the same page as the newest items but claims a 2020 publication date.
    @Test("A back-dated item keeps its old published date and recent insertion time")
    func backDatedItemKeepsBothTimes() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))
        let item = page.items[2]

        #expect(item.published == 1_600_000_000)
        #expect(item.ingestMillis == 1_756_998_000_000)
        // Published long before, inserted moments ago — the two must not be conflated.
        #expect(Int64(item.published!) * 1_000 < item.ingestMillis!)
    }

    @Test("An item with neither summary nor content yields empty HTML rather than failing")
    func missingBodyYieldsEmptyString() throws {
        let item = try JSONDecoder().decode(GReaderItem.self, from: Data("""
        { "id": "tag:google.com,2005:reader/item/0000000000000001" }
        """.utf8))

        #expect(item.contentHTML.isEmpty)
        #expect(item.linkURLString == nil)
    }

    /// `greader.php` always uses compat mode for stream contents, which emits `summary`. A server
    /// configured otherwise sends `content`, and both must work.
    @Test("A body under `content` is used when `summary` is absent")
    func fallsBackToContentField() throws {
        let item = try JSONDecoder().decode(GReaderItem.self, from: Data("""
        {
            "id": "tag:google.com,2005:reader/item/0000000000000001",
            "content": { "content": "<p>Non-compat body.</p>" }
        }
        """.utf8))

        #expect(item.contentHTML == "<p>Non-compat body.</p>")
    }

    @Test("A missing canonical link falls back to alternate")
    func fallsBackToAlternateLink() throws {
        let item = try JSONDecoder().decode(GReaderItem.self, from: Data("""
        {
            "id": "tag:google.com,2005:reader/item/0000000000000001",
            "alternate": [ { "href": "https://example.com/x", "type": "text/html" } ]
        }
        """.utf8))

        #expect(item.linkURLString == "https://example.com/x")
    }

    // MARK: - Item ids

    @Test("Item refs decode from the decimal form")
    func decodesItemRefs() throws {
        let refs = try JSONDecoder().decode(GReaderItemRefs.self, from: fixture("item-ids"))

        #expect(refs.itemRefs.count == 5)
        #expect(refs.continuation == "1685680000000000")
        #expect(refs.itemRefs.last?.id == GReaderItemID(value: 10))
    }

    /// The reconciliation diff in one assertion: ids from `items/ids` must match the ids from
    /// `stream/contents` for the same entries, despite the different wire spellings.
    @Test("Item refs intersect stream contents on identity")
    func itemRefsIntersectStreamContents() throws {
        let page = try JSONDecoder().decode(GReaderStreamContents.self, from: fixture("stream-contents"))
        let refs = try JSONDecoder().decode(GReaderItemRefs.self, from: fixture("item-ids"))

        let fromContents = Set(page.items.map(\.id))
        let fromIDs = Set(refs.itemRefs.map(\.id))

        #expect(fromContents.isSubset(of: fromIDs))
        // And the ids the server still has, minus what we fetched, is what remains to be fetched.
        #expect(fromIDs.subtracting(fromContents).count == 2)
    }
}
