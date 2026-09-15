import Foundation
import SwiftData

/// A feed or timeline that items arrive from, and that appears as a row in the sidebar.
@Model
public final class CachedSource {

    /// Namespaced by provider and account, mirroring `CachedItem.sourceID`:
    /// `freshrss:<accountUUID>:feed/<n>` or `mastodon:<accountUUID>:home`.
    #Unique<CachedSource>([\.id])
    public var id: String = ""

    public var accountID: UUID = UUID()

    /// `ItemKind.rawValue` of the items this source produces.
    public var kindRaw: String = ItemKind.article.rawValue

    public var title: String = ""

    /// The site behind the feed, used as the fallback for favicon discovery and for "open site".
    public var homepageURLString: String?

    /// Favicon as advertised by the server. FreshRSS supplies this in `subscription/list` as
    /// `iconUrl`, which saves discovering it ourselves for the common case.
    public var iconURLString: String?

    /// The FreshRSS category this feed sits in, used to group the sidebar. Optional because
    /// Mastodon timelines have no folder.
    public var folderName: String?

    /// Position among siblings, preserving the order the server returned rather than
    /// re-sorting alphabetically.
    public var sortIndex: Int = 0

    /// Fetch each item's own page and show the article from it, instead of the feed's content.
    ///
    /// Per feed, and off by default, because it is a trade the user has to make knowingly: it
    /// costs one request per item opened and it can fail outright on a client-rendered site. The
    /// feeds worth turning it on for are the ones that publish a truncated summary, which is a
    /// property of the publisher, not something the app can detect from a single item.
    ///
    /// Owned by the app, never by the server — so subscription sync must not touch it. It survives
    /// a refresh because `upsertSources` assigns the fields the server supplies one by one rather
    /// than replacing the row.
    public var loadsFullPageContent: Bool = false

    /// Load and show the discussion under each of this feed's articles.
    ///
    /// Per feed and off by default, for the same reasons as ``loadsFullPageContent`` — it costs
    /// requests against the publisher's server, and only the reader knows whether a given feed's
    /// comments are worth reading. It is also not universally *possible*: the comments come from
    /// WordPress, so a feed published by anything else simply has none to find, which is reported
    /// in the reading pane rather than guessed at here.
    ///
    /// Owned by the app, never by the server, so subscription sync must not touch it. It survives
    /// a refresh because `upsertSources` assigns the fields the server supplies one by one rather
    /// than replacing the row.
    public var loadsComments: Bool = false

    /// Cleared when the source disappears from the server's subscription list. Kept rather than
    /// deleted immediately so its items and reading position survive a transient API hiccup that
    /// returns a short list.
    public var isSubscribed: Bool = true

    public init(
        id: String,
        accountID: UUID,
        kind: ItemKind,
        title: String,
        homepageURLString: String? = nil,
        iconURLString: String? = nil,
        folderName: String? = nil,
        sortIndex: Int = 0,
        isSubscribed: Bool = true,
        loadsFullPageContent: Bool = false,
        loadsComments: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        kindRaw = kind.rawValue
        self.title = title
        self.homepageURLString = homepageURLString
        self.iconURLString = iconURLString
        self.folderName = folderName
        self.sortIndex = sortIndex
        self.isSubscribed = isSubscribed
        self.loadsFullPageContent = loadsFullPageContent
        self.loadsComments = loadsComments
    }

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .article }
        set { kindRaw = newValue.rawValue }
    }

    public var homepageURL: URL? {
        homepageURLString.flatMap(URL.init(string:))
    }

    public var iconURL: URL? {
        iconURLString.flatMap(URL.init(string:))
    }

    /// The scope whose threshold this source owns.
    ///
    /// A Mastodon account's home timeline is stored as an ordinary source but is addressed by the
    /// dedicated `.mastodonHome` scope, because that is the only timeline v1 offers and the
    /// sidebar row belongs to the account rather than to a feed. Those are two different
    /// `ScopeID` raw values over the same items, so anything that reads or writes a source's
    /// position has to agree on which one — a marker seeded against `.source` while the sidebar
    /// counts against `.mastodonHome` would leave the timeline showing zero and the sidebar
    /// showing the whole backlog. This property is that single agreement.
    public var scope: ScopeID {
        kind == .status ? .mastodonHome(accountID: accountID) : .source(id)
    }
}
