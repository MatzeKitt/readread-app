import Foundation

// Wire types for FreshRSS's Google Reader–compatible API.
//
// Field-for-field against `p/api/greader.php` and `FreshRSS_Entry::toGReader()` on `edge`, not
// against the historic Google Reader documentation — FreshRSS implements a subset with its own
// additions (`frss:priority`), and several fields the old docs describe are commented out in the
// source. Anything optional here is optional because FreshRSS can genuinely omit it.

// MARK: - Subscriptions

/// Response of `GET /reader/api/0/subscription/list?output=json`.
public struct GReaderSubscriptionList: Decodable, Sendable {
    public var subscriptions: [GReaderSubscription]

    enum CodingKeys: String, CodingKey {
        case subscriptions
    }

    /// A body with no `subscriptions` key decodes to an empty list rather than throwing.
    ///
    /// The two are handled very differently downstream and the distinction matters: an empty list
    /// is explicitly *not* treated as "unsubscribe everything" by the ingest sink, whereas a throw
    /// becomes a hard account failure. Neither is silently destructive, which is the point.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([GReaderSubscription].self, forKey: .subscriptions) ?? []
    }
}

public struct GReaderSubscription: Decodable, Sendable {

    /// `feed/<numeric id>`.
    public var id: String

    public var title: String

    /// In FreshRSS a feed belongs to exactly one category, so this array always has one element.
    /// Modelled as an array anyway because that is what the wire format says, and a server that
    /// sends none must not fail the whole decode.
    public var categories: [GReaderCategoryRef]

    /// The feed's own XML URL.
    public var url: String?

    /// The website behind the feed. Used for favicon discovery and "open site".
    public var htmlUrl: String?

    /// Favicon URL as resolved by the server.
    ///
    /// Optional *and* frequently the empty string: FreshRSS emits `iconUrl` unconditionally, but
    /// the value is empty when it has no favicon cached, so emptiness has to be treated the same
    /// as absence.
    public var iconUrl: String?

    /// FreshRSS extension. Feeds at or below `PRIORITY_HIDDEN` are omitted from this endpoint
    /// entirely, so a subscription appearing here is always one to show.
    ///
    /// A `String`, because that is what a live FreshRSS actually sends: `"frss:priority":"main"`.
    /// The name, not the number — despite the constants in `FreshRSS_Feed` being integers. Kept as
    /// the raw scalar rather than an enum since nothing in the app branches on it; it is decoded at
    /// all only so that a value the app does not use cannot break the response that carries it.
    public var frssPriority: String?

    enum CodingKeys: String, CodingKey {
        case id, title, categories, url, htmlUrl, iconUrl
        case frssPriority = "frss:priority"
    }

    /// Written out rather than synthesised so that only `id` is actually required.
    ///
    /// Synthesised `Decodable` treats every non-optional property as mandatory, which made the
    /// doc comment on `categories` above a lie: a subscription arriving without that key threw,
    /// and one throw takes down the decode of the **whole list** — every feed in the sidebar
    /// disappears because of one feed's missing field, with nothing to say which. The endpoint
    /// this parses is the one the entire sidebar is built from, so it is worth being generous:
    /// anything the app can carry on without gets a default instead of an error.
    ///
    /// `id` stays required because it is the primary key. A subscription without one cannot be
    /// stored, matched to its items, or told apart from another, so there is nothing to salvage.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        categories = try container.decodeIfPresent([GReaderCategoryRef].self, forKey: .categories) ?? []
        url = try container.decodeIfPresent(String.self, forKey: .url)
        htmlUrl = try container.decodeIfPresent(String.self, forKey: .htmlUrl)
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        frssPriority = try container.decodeScalarIfPresent(forKey: .frssPriority)

        // An untitled feed shows as its stream id, which is at least identifying and clickable.
        // A blank sidebar row is not.
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        title = decodedTitle.isEmpty ? id : decodedTitle
    }

    /// The numeric feed id, or `nil` if the prefix is missing.
    public var feedID: String? {
        guard id.hasPrefix("feed/") else { return nil }
        return String(id.dropFirst("feed/".count))
    }

    /// The category name, normalised so an empty or absent one reads as "no folder".
    public var folderName: String? {
        guard let label = categories.first?.folderName, !label.isEmpty else { return nil }
        return label
    }

    /// `iconUrl` with empty strings normalised away.
    public var iconURLString: String? {
        guard let iconUrl, !iconUrl.isEmpty else { return nil }
        return iconUrl
    }

    public var homepageURLString: String? {
        guard let htmlUrl, !htmlUrl.isEmpty else { return nil }
        return htmlUrl
    }
}

public struct GReaderCategoryRef: Decodable, Sendable {

    /// `user/-/label/<name>`.
    public var id: String

    /// Present on subscriptions, absent in `tag/list`.
    public var label: String?

    enum CodingKeys: String, CodingKey {
        case id, label
    }

    /// Tolerant for the same reason as ``GReaderSubscription``: a category the app cannot name
    /// should cost that one feed its folder, not cost the user their whole sidebar.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    /// The category name, taken from `label` when present and otherwise parsed out of `id`.
    ///
    /// Parsed with a plain prefix drop rather than by splitting on `/`, because category names are
    /// user-chosen free text and may themselves contain slashes.
    public var folderName: String? {
        if let label, !label.isEmpty { return label }
        let prefix = "user/-/label/"
        guard id.hasPrefix(prefix) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }
}

// MARK: - Tags

/// Response of `GET /reader/api/0/tag/list?output=json`.
public struct GReaderTagList: Decodable, Sendable {
    public var tags: [GReaderTag]
}

public struct GReaderTag: Decodable, Sendable {

    /// Either `user/-/state/...` for built-in streams or `user/-/label/<name>`.
    public var id: String

    /// `"folder"` for a FreshRSS category, `"tag"` for a user label. Absent for built-in states.
    ///
    /// This field is the *only* thing separating the two: FreshRSS emits categories and labels
    /// under the same `user/-/label/` prefix, so a category and a tag sharing a name are
    /// indistinguishable by id alone. Folders are what the sidebar groups by, so it filters on
    /// this rather than trusting the prefix.
    public var type: String?

    public var unreadCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, type
        case unreadCount = "unread_count"
    }

    /// Written out so a count arriving quoted is still a count.
    ///
    /// FreshRSS quotes some numbers and not others — `crawlTimeMsec` is a string, `published` is a
    /// number — and which is which is not something to be confident about from reading one
    /// server's output. Where the app can shrug off the difference, it does.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeScalarIfPresent(forKey: .type)
        unreadCount = try container.decodeScalarIfPresent(forKey: .unreadCount).flatMap(Int.init)
    }

    public var isFolder: Bool { type == "folder" }

    public var folderName: String? {
        let prefix = "user/-/label/"
        guard id.hasPrefix(prefix) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }
}

// MARK: - Stream contents

/// Response of `GET /reader/api/0/stream/contents/...`.
public struct GReaderStreamContents: Decodable, Sendable {

    public var id: String?
    public var updated: Int?
    public var items: [GReaderItem]

    /// Present only when more items remain. Its absence is how a walk knows it has reached the end
    /// of the stream, so this being optional is load-bearing, not defensive.
    public var continuation: String?
}

public struct GReaderItem: Decodable, Sendable {

    /// The tag-URI form; normalised through `GReaderItemID` on decode.
    public var id: GReaderItemID

    /// When the item was published, epoch seconds. Drives display order.
    public var published: Int?

    /// Server-side insertion time in **microseconds**, as a string because it exceeds `Int32` and
    /// FreshRSS sends it quoted.
    public var timestampUsec: String?

    /// Server-side insertion time in **milliseconds**, also quoted.
    ///
    /// This is the app's `ingestKey` source: it is the server's `date_added`, so it is identical on
    /// every device — unlike local wall time, which would make late-arrival detection disagree
    /// between the Mac and the phone.
    public var crawlTimeMsec: String?

    public var title: String?
    public var author: String?
    public var canonical: [GReaderLink]?
    public var alternate: [GReaderLink]?

    /// The article body. FreshRSS caps this at 500 KB, which in practice is the full content — so
    /// there is no second request to make for the full text.
    public var summary: GReaderContent?

    /// Present instead of `summary` only in non-compat mode, which `greader.php` never uses for
    /// stream contents. Decoded anyway so a differently-configured server still works.
    public var content: GReaderContent?

    public var origin: GReaderOrigin?
    public var categories: [String]?
    public var enclosure: [GReaderEnclosure]?

    // MARK: Derived

    /// Best available body HTML.
    public var contentHTML: String {
        summary?.content ?? content?.content ?? ""
    }

    /// The article's own URL.
    public var linkURLString: String? {
        let candidate = canonical?.first?.href ?? alternate?.first?.href
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    public var publishedDate: Date? {
        published.map { Date(timeIntervalSince1970: Double($0)) }
    }

    /// Server insertion time, in epoch milliseconds.
    ///
    /// Prefers `crawlTimeMsec` and falls back to `timestampUsec / 1000`. They are the same instant
    /// at different scales, and at least one is always present.
    public var ingestMillis: Int64? {
        if let crawlTimeMsec, let millis = Int64(crawlTimeMsec) {
            return millis
        }
        if let timestampUsec, let micros = Int64(timestampUsec) {
            return micros / 1_000
        }
        return nil
    }

    /// `feed/<n>` this item came from.
    public var originStreamID: String? {
        guard let streamId = origin?.streamId, !streamId.isEmpty else { return nil }
        return streamId
    }
}

public struct GReaderLink: Decodable, Sendable {
    public var href: String?
    public var type: String?
}

public struct GReaderContent: Decodable, Sendable {
    public var content: String?
    public var direction: String?
}

public struct GReaderOrigin: Decodable, Sendable {
    public var streamId: String?
    public var title: String?
    public var htmlUrl: String?
    public var feedUrl: String?
}

public struct GReaderEnclosure: Decodable, Sendable {
    public var href: String?
    public var type: String?
    public var length: Int?
}

// MARK: - Item ids

/// Response of `GET /reader/api/0/stream/items/ids`.
///
/// Used by the reconciliation pass: ids alone are cheap enough to fetch a thousand at a time, which
/// is what makes it affordable to notice server-side deletions that a purely additive descending
/// walk can never see.
public struct GReaderItemRefs: Decodable, Sendable {
    public var itemRefs: [GReaderItemRef]
    public var continuation: String?
}

public struct GReaderItemRef: Decodable, Sendable {
    /// Bare decimal on the wire; normalised through `GReaderItemID` on decode.
    public var id: GReaderItemID
}

// MARK: - User info

/// Response of `GET /reader/api/0/user-info`.
public struct GReaderUserInfo: Decodable, Sendable {
    public var userId: String?
    public var userName: String?
    public var userEmail: String?
}


// MARK: - Lenient scalars

private extension KeyedDecodingContainer {

    /// Decodes a value that may arrive as a string, a number or a boolean, as its string form.
    ///
    /// Exists because of one field and the class of bug it represents. `frss:priority` was modelled
    /// as `Int` from FreshRSS's integer priority constants; a live server sends `"main"`. The
    /// mismatch threw, one throw failed the decode of the **entire** subscription list, and the app
    /// showed an empty sidebar with a 200 in the log and nothing to attribute it to — for a field
    /// it never reads.
    ///
    /// So: where the app does not depend on a field's type, it should not fail on it. This is not a
    /// licence to be vague about fields that matter — `id` and the sort keys are still decoded
    /// strictly, because getting those wrong must be loud.
    func decodeScalarIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return String(value) }
        return nil
    }
}
